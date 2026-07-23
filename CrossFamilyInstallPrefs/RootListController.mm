#import "RootListController.h"
#import <UIKit/UIKit.h>

// State is delivered to installd over Darwin notifications, not a shared
// plist. installd is a sandboxed root daemon and cannot read
// /var/mobile/Library/Preferences - see the long comment in Tweak.xm. A local
// plist is still kept here so the switch shows the right position in the UI.
static NSString *CrossFamilyUIPrefsPath(void) {
    NSString *root = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"/var/jb" : @"";
    return [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/com.soulrune.crossfamilyinstall.plist", root];
}

// Same path installd persists to. Writing it from here as well is what makes
// a single tap sufficient: if installd happens to be running, the notification
// below updates it live; if it is NOT running, the notification goes nowhere -
// but then there is also nothing to restart, and the next time launchd starts
// installd on demand it reads this file and comes up with the correct state.
// Between the two, every case is covered without waking the daemon or asking
// launchctl to restart it.
static NSString *CrossFamilyStatePath(void) {
    return @"/var/tmp/com.soulrune.crossfamilyinstall.state";
}

static void CrossFamilyPostState(BOOL enabled) {
    NSError *error = nil;
    BOOL ok = [(enabled ? @"1" : @"0") writeToFile:CrossFamilyStatePath()
                                        atomically:YES
                                          encoding:NSUTF8StringEncoding
                                             error:&error];
    NSLog(@"[CrossFamilyInstallPrefs] state file write -> %@ %@",
          ok ? @"OK" : @"FAILED", ok ? @"" : error.localizedDescription);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        enabled ? CFSTR("com.soulrune.crossfamilyinstall/enable")
                : CFSTR("com.soulrune.crossfamilyinstall/disable"),
        NULL, NULL, YES);
}

@implementation CrossFamilyInstallRootListController

#pragma mark - Specifier builders

- (PSSpecifier *)groupNamed:(NSString *)title footer:(NSString *)footer {
    PSSpecifier *s = [PSSpecifier groupSpecifierWithName:title];
    if (footer.length) {
        [s setProperty:footer forKey:@"footerText"];
    }
    return s;
}

- (PSSpecifier *)switchSpecifierNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                     target:self
                                                        set:@selector(setPreferenceValue:specifier:)
                                                        get:@selector(readPreferenceValue:)
                                                     detail:Nil
                                                       cell:PSSwitchCell
                                                       edit:Nil];
    [s setProperty:key forKey:@"key"];
    [s setProperty:@NO forKey:@"default"];
    return s;
}

- (PSSpecifier *)buttonNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                     target:self
                                                        set:NULL
                                                        get:NULL
                                                     detail:NULL
                                                       cell:PSButtonCell
                                                       edit:NULL];
    s->action = action;
    [s setProperty:@YES forKey:@"enabled"];
    return s;
}

#pragma mark - Specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[self groupNamed:@"CrossFamilyInstall"
                                    footer:@"Allows installing IPAs built for a different device "
                                           @"family (iPhone/iPad/tvOS). Works at the installer level - "
                                           @"the app itself may still crash on launch (interface/frameworks "
                                           @"mismatch), especially for tvOS."]];
        [specs addObject:[self switchSpecifierNamed:@"Allow Installation" key:@"Enabled"]];

        [specs addObject:[self groupNamed:@""
                                    footer:@"installd is a long-running daemon: after installing/updating "
                                           @"the tweak or changing the switch, tap Apply to restart it "
                                           @"(re-injects the tweak, clears its internal install-verdict "
                                           @"cache). A regular SpringBoard respring won't help here - "
                                           @"installd is a separate process."]];
        [specs addObject:[self buttonNamed:@"Apply (Restart installd)" action:@selector(applySettings)]];

        _specifiers = [specs copy];
    }
    return _specifiers;
}

#pragma mark - Preferences persistence
//
// Mirrors ARStore's setBool:forKey:/boolForKey: pattern directly.

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSString *path = CrossFamilyUIPrefsPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    prefs[key] = value;
    [prefs writeToFile:path atomically:YES];

    // The authoritative channel: tell installd directly. This is what actually
    // takes effect - the plist above only backs the switch's UI position.
    if ([key isEqualToString:@"Enabled"]) {
        CrossFamilyPostState([value boolValue]);
    }
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:CrossFamilyUIPrefsPath()];
    return @([prefs[key] boolValue]);
}

#pragma mark - Apply (restart installd)
//
// Doesn't spawn/exec anything - just posts a Darwin notification, which is
// always permitted across UIDs regardless of sandbox/jailbreak specifics
// (unlike asking launchctl to kickstart a root daemon from a mobile-owned
// process, which is unreliable). The tweak, already injected into installd
// (running as root), receives it and exits itself; launchd relaunches the
// daemon using its own privilege, no cross-process privilege elevation
// needed on our end at all.

- (void)applySettings {
    // Re-post current state first, so a fresh installd instance comes up with
    // the right value even if it missed the original toggle notification, then
    // ask it to restart (clears its in-memory install-verdict cache).
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:CrossFamilyUIPrefsPath()];
    BOOL enabled = [prefs[@"Enabled"] boolValue];
    CrossFamilyPostState(enabled);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.soulrune.crossfamilyinstall/restart"),
        NULL, NULL, YES);

    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];

    [self toast:@"Applied"
        message:[NSString stringWithFormat:
                 @"State (%@) saved and sent to installd, and a restart was "
                 @"requested. If installd wasn't running, it will pick the "
                 @"state up on its next launch - no second tap needed.",
                 enabled ? @"enabled" : @"disabled"]];
}

- (void)toast:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
