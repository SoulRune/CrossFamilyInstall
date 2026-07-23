#import <Foundation/Foundation.h>
#import <substrate.h>
#import <sys/sysctl.h>
#import <stdlib.h>

// installd is a headless daemon with no UIKit, so we read the version via
// sysctlbyname instead of UIDevice (avoids pulling in a framework the
// process never loads).
static NSString *CrossFamilyOSVersion(void) {
    size_t size = 0;
    if (sysctlbyname("kern.osproductversion", NULL, &size, NULL, 0) != 0 || size == 0) {
        return @"unknown";
    }
    char *buf = (char *)malloc(size);
    if (!buf) return @"unknown";
    NSString *version = @"unknown";
    if (sysctlbyname("kern.osproductversion", buf, &size, NULL, 0) == 0) {
        version = [NSString stringWithUTF8String:buf];
    }
    free(buf);
    return version;
}

// ==========================================================================
// STATE / TOGGLE
// ==========================================================================
//
// Why this is NOT AutoRotate's plist-file scheme, despite that being the
// reference implementation for this project: AutoRotate's dylib is injected
// into UIKit apps, which run as `mobile`, so reading
// /var/mobile/Library/Preferences/<domain>.plist is reading their own user's
// preferences directory - trivially permitted. Our dylib lives inside
// installd, a SANDBOXED ROOT DAEMON. Sandbox profiles apply on top of UID, so
// being root does not grant it read access to /var/mobile/Library/Preferences
// - which is exactly why the toggle kept having no effect even when the plist
// was demonstrably written correctly and installd was restarted as root.
//
// So the state is delivered over Darwin notifications instead: those cross
// sandbox and UID boundaries unconditionally, which is precisely why they're
// the standard IPC for this situation. The Settings panel posts enable/disable;
// we hold the state in memory. For persistence across installd restarts we
// write a copy to a file installd itself owns and wrote - no cross-process
// permission question can arise for a file the reading process created.

static BOOL gEnabled = NO;

static NSString *CrossFamilyStatePath(void) {
    // Written and read exclusively by installd itself.
    return @"/var/tmp/com.soulrune.crossfamilyinstall.state";
}

static void CrossFamilyPersistState(void) {
    NSString *value = gEnabled ? @"1" : @"0";
    NSError *error = nil;
    BOOL ok = [value writeToFile:CrossFamilyStatePath()
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:&error];
    NSLog(@"[CrossFamilyInstall] persist state=%@ -> %@ (%@)",
          value, ok ? @"OK" : @"FAILED", ok ? @"" : error.localizedDescription);
}

static void CrossFamilyLoadPersistedState(void) {
    NSString *value = [NSString stringWithContentsOfFile:CrossFamilyStatePath()
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
    gEnabled = [[value stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]] isEqualToString:@"1"];
    NSLog(@"[CrossFamilyInstall] loaded persisted state -> enabled=%d", gEnabled);
}

static void CrossFamilyEnableReceived(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    gEnabled = YES;
    NSLog(@"[CrossFamilyInstall] enable notification received");
    CrossFamilyPersistState();
}

static void CrossFamilyDisableReceived(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object,
                                        CFDictionaryRef userInfo) {
    gEnabled = NO;
    NSLog(@"[CrossFamilyInstall] disable notification received");
    CrossFamilyPersistState();
}

static BOOL CrossFamilyIsEnabled(void) {
    return gEnabled;
}

// ==========================================================================
// APPLY BUTTON - restart request
// ==========================================================================

static void CrossFamilyRestartRequested(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo) {
    // A process can always exit itself - no privilege boundary involved,
    // unlike asking launchctl (from the mobile-owned Settings process) to
    // kickstart a root daemon. launchd relaunches installd automatically,
    // which also clears its in-memory install-verdict cache.
    NSLog(@"[CrossFamilyInstall] restart requested - exiting so launchd respawns installd");
    exit(0);
}

// ==========================================================================
// THE ACTUAL HOOK - found via tracing (see errors.log / REVERSE_ENGINEERING.md):
//
// domain: MIInstallerErrorDomain, code: 10
// FunctionName = MIIsApplicableToCurrentDeviceFamilyWithError
// Module: /System/Library/PrivateFrameworks/InstalledContentLibrary.framework
//
// Call chain:
//   -[MIInstaller performInstallationWithError:]
//   -[MIInstaller _installInstallable:containingSymlink:error:]
//   -[MIInstallableBundle _verifyBundleMetadataWithError:]
//   -[MIBundle isApplicableToCurrentDeviceFamilyWithError:]
//   MIIsApplicableToCurrentDeviceFamilyWithError()   <-- hooked here
// ==========================================================================

#define TARGET_SYMBOL "MIIsApplicableToCurrentDeviceFamilyWithError"

// NOTE on the signature: the exact argument count/types haven't been confirmed
// yet (see inspect_family_check.js - run it and check the output to pin this
// down precisely). In the meantime this declares six generic pointer-sized
// parameters (matching x0-x5 under AAPCS64) instead of void(void). This isn't
// just cosmetic: a bare void(void) hook has NO named parameters, so the
// compiler has no reason to preserve the caller's original x0-x3 register
// values across any function calls inside our hook body (e.g. the call to
// CrossFamilyIsEnabled()) - those registers are caller-saved and get silently
// clobbered, so calling through to OrigFamilyCheck() on the disabled path ends
// up forwarding garbage instead of the real arguments. Declaring named
// parameters (even generically typed) forces the compiler to spill/reload them
// correctly around calls, which is required for the disabled/pass-through path
// to behave correctly. Extra unused parameter slots beyond the real arity are
// harmless. The enabled/bypass path (`return YES`) never touches these at all,
// so it's unaffected either way.
typedef BOOL (*OrigFamilyCheck_t)(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5);
static OrigFamilyCheck_t OrigFamilyCheck;

static BOOL Replaced_FamilyCheck(void *a0, void *a1, void *a2, void *a3, void *a4, void *a5) {
    BOOL enabled = CrossFamilyIsEnabled();
    NSLog(@"[CrossFamilyInstall] family check fired, toggle enabled=%d", enabled);
    if (enabled) {
        return YES;
    }
    return OrigFamilyCheck ? OrigFamilyCheck(a0, a1, a2, a3, a4, a5) : NO;
}

// ==========================================================================
// CONSTRUCTOR
// ==========================================================================

%ctor {
    @autoreleasepool {
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, CrossFamilyRestartRequested,
            CFSTR("com.soulrune.crossfamilyinstall/restart"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, CrossFamilyEnableReceived,
            CFSTR("com.soulrune.crossfamilyinstall/enable"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, CrossFamilyDisableReceived,
            CFSTR("com.soulrune.crossfamilyinstall/disable"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);

        CrossFamilyLoadPersistedState();

        NSString *osVersion = CrossFamilyOSVersion();

        // MSFindSymbol(NULL, ...) searches across all loaded images - that's
        // enough, since InstalledContentLibrary is already loaded by the time
        // installd starts (confirmed by the fact that errors.log's backtrace
        // includes calls from this framework on the normal install path).
        void *sym = MSFindSymbol(NULL, "_" TARGET_SYMBOL);
        if (!sym) {
            // some runtimes expect the symbol name without a leading underscore
            sym = MSFindSymbol(NULL, TARGET_SYMBOL);
        }
        if (sym) {
            MSHookFunction(sym, (void *)Replaced_FamilyCheck, (void **)&OrigFamilyCheck);
            NSLog(@"[CrossFamilyInstall] hooked %s at %p (iOS %@)", TARGET_SYMBOL, sym, osVersion);
        } else {
            NSLog(@"[CrossFamilyInstall] symbol %s NOT FOUND on iOS %@ - tweak inactive", TARGET_SYMBOL, osVersion);
        }
    }
}
