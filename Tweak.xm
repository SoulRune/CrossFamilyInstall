#import <Foundation/Foundation.h>
#import <substrate.h>
#import <sys/sysctl.h>
#import <stdlib.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <os/lock.h>

// installd has no UIKit, so the version comes from sysctl.
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
// installd is a sandboxed root daemon and can't read the panel's plist in
// /var/mobile/Library/Preferences. Instead:
//  1. A state file in /var/tmp, re-checked (one stat) on every compatibility
//     check, so a switch flipped while installd wasn't running still applies.
//  2. Darwin notifications update a running installd right away.
// Both sides write the file in place: /var/tmp is sticky, so a rename over the
// other side's file would be refused. installd keeps it at mode 0666.

// The state is a bitmask, one bit per check that can be skipped.

typedef NS_OPTIONS(unsigned int, CrossFamilyFlags) {
    CrossFamilyFlagFamily   = 1u << 0,  // UIDeviceFamily (iPhone/iPad/tvOS)
    CrossFamilyFlagModel    = 1u << 1,  // device model / UIRequiredDeviceCapabilities / UISupportedDevices
    CrossFamilyFlagOS       = 1u << 2,  // MinimumOSVersion
};

static const char *const kCrossFamilyStatePath = "/var/tmp/com.soulrune.crossfamilyinstall.state";

static unsigned int gFlags = 0;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
// Identity of the file version gFlags was last loaded from.
static BOOL gStateSeen = NO;
static ino_t gStateIno = 0;
static off_t gStateSize = 0;
static struct timespec gStateMtime = {0, 0};

static BOOL CrossFamilyReadStateFile(unsigned int *out) {
    int fd = open(kCrossFamilyStatePath, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    char buf[32] = {0};
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return NO;                 // missing, or caught mid-rewrite
    char *end = NULL;
    unsigned long value = strtoul(buf, &end, 10);
    if (end == buf) return NO;             // garbage: keep the previous state
    *out = (unsigned int)value;
    return YES;
}

// In place, mode 0666 (see above).
static BOOL CrossFamilyWriteStateFile(unsigned int flags) {
    int fd = open(kCrossFamilyStatePath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
    if (fd < 0) {
        NSLog(@"[CrossFamilyInstall] state file open failed: %s", strerror(errno));
        return NO;
    }
    fchmod(fd, 0666);                      // undo umask; harmless when not the owner
    char buf[16];
    int len = snprintf(buf, sizeof(buf), "%u\n", flags);
    BOOL ok = write(fd, buf, (size_t)len) == len;
    close(fd);
    return ok;
}

// Must be called with gStateLock held.
static void CrossFamilyRefreshLocked(void) {
    struct stat st;
    if (stat(kCrossFamilyStatePath, &st) != 0) return;   // no file: keep in-memory state
    if (gStateSeen && st.st_ino == gStateIno && st.st_size == gStateSize &&
        st.st_mtimespec.tv_sec == gStateMtime.tv_sec &&
        st.st_mtimespec.tv_nsec == gStateMtime.tv_nsec) {
        return;                                          // unchanged since last read
    }
    unsigned int flags = 0;
    if (!CrossFamilyReadStateFile(&flags)) return;       // retry on the next check
    gStateSeen = YES;
    gStateIno = st.st_ino;
    gStateSize = st.st_size;
    gStateMtime = st.st_mtimespec;
    if (flags != gFlags) {
        NSLog(@"[CrossFamilyInstall] state file changed: flags 0x%x -> 0x%x", gFlags, flags);
        gFlags = flags;
    }
}

static unsigned int CrossFamilyCurrentFlags(void) {
    os_unfair_lock_lock(&gStateLock);
    CrossFamilyRefreshLocked();
    unsigned int flags = gFlags;
    os_unfair_lock_unlock(&gStateLock);
    return flags;
}

static BOOL CrossFamilyFlagIsSet(CrossFamilyFlags flag) {
    return (CrossFamilyCurrentFlags() & flag) != 0;
}

static void CrossFamilySetFlag(CrossFamilyFlags flag, BOOL on, const char *what) {
    os_unfair_lock_lock(&gStateLock);
    CrossFamilyRefreshLocked();            // don't clobber bits set via the file meanwhile
    if (on) gFlags |= flag; else gFlags &= ~flag;
    unsigned int flags = gFlags;
    BOOL ok = CrossFamilyWriteStateFile(flags);
    os_unfair_lock_unlock(&gStateLock);
    NSLog(@"[CrossFamilyInstall] %s -> %s (flags=0x%x, persist %@)",
          what, on ? "ON" : "OFF", flags, ok ? @"OK" : @"FAILED");
}

// One Darwin notification per switch position.
#define CFI_OBSERVER(fn, flag, on, label) \
    static void fn(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) { \
        CrossFamilySetFlag(flag, on, label); \
    }
CFI_OBSERVER(CrossFamilyEnableReceived,       CrossFamilyFlagFamily, YES, "ignore device family")
CFI_OBSERVER(CrossFamilyDisableReceived,      CrossFamilyFlagFamily, NO,  "ignore device family")
CFI_OBSERVER(CrossFamilyModelEnableReceived,  CrossFamilyFlagModel,  YES, "ignore device model")
CFI_OBSERVER(CrossFamilyModelDisableReceived, CrossFamilyFlagModel,  NO,  "ignore device model")
CFI_OBSERVER(CrossFamilyOSEnableReceived,     CrossFamilyFlagOS,     YES, "ignore OS version")
CFI_OBSERVER(CrossFamilyOSDisableReceived,    CrossFamilyFlagOS,     NO,  "ignore OS version")
#undef CFI_OBSERVER

static void CrossFamilyLoadPersistedState(void) {
    // Settings can't write a root-owned 0644 file; installd owns it, so fix it here
    chmod(kCrossFamilyStatePath, 0666);
    unsigned int flags = CrossFamilyCurrentFlags();
    NSLog(@"[CrossFamilyInstall] loaded persisted state -> flags=0x%x", flags);
}

static BOOL CrossFamilyIsEnabled(void) {
    return CrossFamilyFlagIsSet(CrossFamilyFlagFamily);
}

// ==========================================================================
// APPLY BUTTON - restart request
// ==========================================================================

static void CrossFamilyRestartRequested(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo) {
    // launchd starts installd again, which also clears its verdict cache
    NSLog(@"[CrossFamilyInstall] restart requested - exiting so launchd respawns installd");
    exit(0);
}

// ==========================================================================
// DEVICE FAMILY CHECK (see docs/REVERSE_ENGINEERING.md)
//
// MIInstallerErrorDomain code 10, raised by
// MIIsApplicableToCurrentDeviceFamilyWithError
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

// The exact signature isn't known, so six pointer-sized parameters (x0-x5) are
// declared and passed on unchanged. Without named parameters the compiler
// wouldn't keep the caller's registers across the hook's own calls, and the original
// would get garbage when the toggle is off.
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

// Most specific first: the InstalledContentLibrary image (behaves the same on
// every hooking library), then dlsym, then a search of all images.
static void *CrossFamilyFindFamilySymbol(const char **how) {
    static const char *const kICLPath =
        "/System/Library/PrivateFrameworks/InstalledContentLibrary.framework/InstalledContentLibrary";
    void *sym = NULL;

    MSImageRef image = MSGetImageByName(kICLPath);
    if (image) {
        sym = MSFindSymbol(image, "_" TARGET_SYMBOL);
        if (sym) { *how = "MSFindSymbol(InstalledContentLibrary)"; return sym; }
    } else {
        NSLog(@"[CrossFamilyInstall] InstalledContentLibrary image not found by path, falling back");
    }

    sym = dlsym(RTLD_DEFAULT, TARGET_SYMBOL);
    if (sym) { *how = "dlsym"; return sym; }

    sym = MSFindSymbol(NULL, "_" TARGET_SYMBOL);
    if (!sym) sym = MSFindSymbol(NULL, TARGET_SYMBOL);   // some runtimes want no underscore
    if (sym) { *how = "MSFindSymbol(NULL)"; return sym; }
    return NULL;
}

// ==========================================================================
// DEVICE MODEL / OS VERSION CHECKS (+ ObjC-level family fallback)
// ==========================================================================
//
// installd asks the bundle a series of "applicable to this device?" questions,
// ObjC methods shaped like
//     - (BOOL)isApplicableToCurrent<Thing>WithError:(NSError **)error;
//     - (BOOL)isApplicableTo<Thing>:(id)value error:(NSError **)error;
// Names change between iOS versions, so the classes are scanned at load and a
// method is wrapped only if both its name and its exact type encoding match.
// A wrong guess means "not hooked", never a crash. Every candidate is logged:
//   [CrossFamilyInstall] candidate -[MIBundle isApplicableToCurrentOSVersionWithError:] B24@0:8^@16 -> hooked (os)

typedef BOOL (*CFIErrIMP)(id, SEL, NSError **);
typedef BOOL (*CFIArgErrIMP)(id, SEL, id, NSError **);

// Which switch a selector belongs to, by name. 0 == none.
static CrossFamilyFlags CrossFamilyFlagForSelector(NSString *name) {
    if (!([name hasPrefix:@"isApplicable"] || [name hasPrefix:@"isCompatible"])) return 0;
    NSString *lower = name.lowercaseString;
    // Family: a backup for the C hook, in case that function is renamed or
    // inlined on some iOS version
    if ([lower containsString:@"devicefamily"]) return CrossFamilyFlagFamily;
    if ([lower containsString:@"osversion"] || [lower containsString:@"systemversion"] ||
        [lower containsString:@"minimumos"] || [lower containsString:@"platformversion"]) {
        return CrossFamilyFlagOS;
    }
    if ([lower containsString:@"capabilit"] || [lower containsString:@"supporteddevice"] ||
        [lower containsString:@"devicemodel"] || [lower containsString:@"devicetype"] ||
        [lower containsString:@"hardware"]) {
        return CrossFamilyFlagModel;
    }
    return 0;
}

// Type encoding with the offset digits stripped: "B24@0:8^@16" -> "B@:^@".
static NSString *CrossFamilyShape(Method m) {
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return @"";
    NSMutableString *out = [NSMutableString string];
    for (const char *p = enc; *p; p++) {
        if (*p < '0' || *p > '9') [out appendFormat:@"%c", *p];
    }
    return out;
}

static const char *CrossFamilyFlagLabel(CrossFamilyFlags f) {
    switch (f) {
        case CrossFamilyFlagFamily: return "family";
        case CrossFamilyFlagOS:     return "os";
        default:                    return "model";
    }
}

static BOOL CrossFamilyWrapMethod(Class cls, Method m, CrossFamilyFlags flag) {
    SEL sel = method_getName(m);
    NSString *shape = CrossFamilyShape(m);
    // 'B' (bool) on arm64; 'c' (signed char BOOL) accepted just in case.
    BOOL oneArg = [shape isEqualToString:@"B@:^@"] || [shape isEqualToString:@"c@:^@"];
    BOOL twoArg = [shape isEqualToString:@"B@:@^@"] || [shape isEqualToString:@"c@:@^@"];
    if (!oneArg && !twoArg) return NO;

    NSString *where = [NSString stringWithFormat:@"-[%s %s]", class_getName(cls), sel_getName(sel)];
    IMP orig = method_getImplementation(m);
    id block;
    if (oneArg) {
        CFIErrIMP o = (CFIErrIMP)orig;
        block = ^BOOL(id self, NSError **error) {
            if (CrossFamilyFlagIsSet(flag)) {
                NSLog(@"[CrossFamilyInstall] %@ bypassed (%s)", where, CrossFamilyFlagLabel(flag));
                if (error) *error = nil;
                return YES;
            }
            return o(self, sel, error);
        };
    } else {
        CFIArgErrIMP o = (CFIArgErrIMP)orig;
        block = ^BOOL(id self, id arg, NSError **error) {
            if (CrossFamilyFlagIsSet(flag)) {
                NSLog(@"[CrossFamilyInstall] %@ bypassed (%s)", where, CrossFamilyFlagLabel(flag));
                if (error) *error = nil;
                return YES;
            }
            return o(self, sel, arg, error);
        };
    }
    method_setImplementation(m, imp_implementationWithBlock(block));
    return YES;
}

static unsigned CrossFamilyHookImage(const char *image) {
    unsigned hooked = 0, classCount = 0;
    const char **names = objc_copyClassNamesForImage(image, &classCount);
    if (!names) return 0;
    for (unsigned i = 0; i < classCount; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;
        unsigned methodCount = 0;
        // Instance methods defined directly on this class only - subclasses
        // get their own pass, so nothing is wrapped twice.
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned j = 0; j < methodCount; j++) {
            NSString *name = NSStringFromSelector(method_getName(methods[j]));
            CrossFamilyFlags flag = CrossFamilyFlagForSelector(name);
            if (!flag) continue;
            BOOL ok = CrossFamilyWrapMethod(cls, methods[j], flag);
            if (ok) hooked++;
            NSLog(@"[CrossFamilyInstall] candidate -[%s %@] %s -> %@",
                  names[i], name, method_getTypeEncoding(methods[j]) ?: "?",
                  ok ? [NSString stringWithFormat:@"hooked (%s)", CrossFamilyFlagLabel(flag)]
                     : @"skipped (unexpected signature)");
        }
        free(methods);
    }
    free(names);
    return hooked;
}

static void CrossFamilyHookCompatibilityChecks(NSString *osVersion) {
    unsigned hooked = 0;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *image = _dyld_get_image_name(i);
        if (!image) continue;
        // i == 0 is installd's own executable.
        if (i == 0 || strstr(image, "/InstalledContentLibrary.framework/") ||
                      strstr(image, "/MobileInstallation.framework/")) {
            hooked += CrossFamilyHookImage(image);
        }
    }
    NSLog(@"[CrossFamilyInstall] ObjC checks: %u method(s) hooked on iOS %@%@", hooked, osVersion,
          hooked ? @"" : @" - ignore model/OS switches will have no effect");
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
        CFNotificationCenterAddObserver(darwin, NULL, CrossFamilyModelEnableReceived,
            CFSTR("com.soulrune.crossfamilyinstall/model/enable"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, CrossFamilyModelDisableReceived,
            CFSTR("com.soulrune.crossfamilyinstall/model/disable"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, CrossFamilyOSEnableReceived,
            CFSTR("com.soulrune.crossfamilyinstall/os/enable"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, CrossFamilyOSDisableReceived,
            CFSTR("com.soulrune.crossfamilyinstall/os/disable"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);

        CrossFamilyLoadPersistedState();

        NSString *osVersion = CrossFamilyOSVersion();

        const char *how = NULL;
        void *sym = CrossFamilyFindFamilySymbol(&how);
        if (sym) {
            MSHookFunction(sym, (void *)Replaced_FamilyCheck, (void **)&OrigFamilyCheck);
            NSLog(@"[CrossFamilyInstall] hooked %s at %p via %s (iOS %@)", TARGET_SYMBOL, sym, how, osVersion);
        } else {
            NSLog(@"[CrossFamilyInstall] symbol %s NOT FOUND on iOS %@ - C-level family hook inactive (ObjC fallback below may still cover it)", TARGET_SYMBOL, osVersion);
        }

        // Independent of the family hook - each part fails safe on its own.
        CrossFamilyHookCompatibilityChecks(osVersion);
    }
}
