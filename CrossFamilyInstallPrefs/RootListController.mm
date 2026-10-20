#import "RootListController.h"
#import "CFIAppsTableController.h"
#import "CFIAppSpoofController.h"
#import "CFISpoofListBase.h"
#import "CFISpoofStore.h"
#import <UIKit/UIKit.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

// installd is sandboxed and can't read /var/mobile/Library/Preferences, so it
// gets the state through Darwin notifications and a state file (see Tweak.xm).
// This plist only keeps the switches' positions.
static NSString *CrossFamilyUIPrefsPath(void) {
    NSString *root = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"/var/jb" : @"";
    return [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/com.soulrune.crossfamilyinstall.plist", root];
}

// The file installd reads when it starts, so the state holds even if it wasn't
// running when a switch changed. Written in place: /var/tmp is sticky, so a
// rename over installd's (root-owned) file would be refused.
static const char *const kCrossFamilyStatePath = "/var/tmp/com.soulrune.crossfamilyinstall.state";

static BOOL CrossFamilyWriteStateFile(unsigned int flags, NSString **why) {
    int fd = open(kCrossFamilyStatePath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
    if (fd < 0) {
        if (why) *why = [NSString stringWithUTF8String:strerror(errno)];
        return NO;
    }
    fchmod(fd, 0666);
    char buf[16];
    int len = snprintf(buf, sizeof(buf), "%u\n", flags);
    BOOL ok = write(fd, buf, (size_t)len) == len;
    if (!ok && why) *why = [NSString stringWithUTF8String:strerror(errno)];
    close(fd);
    return ok;
}

// Bit layout shared with Tweak.xm.
static const unsigned int kFlagFamily = 1u << 0;
static const unsigned int kFlagModel  = 1u << 1;
static const unsigned int kFlagOS     = 1u << 2;

static unsigned int CrossFamilyFlagsFromPrefs(NSDictionary *prefs) {
    unsigned int flags = 0;
    if ([prefs[@"Enabled"] boolValue])           flags |= kFlagFamily;
    if ([prefs[@"IgnoreDeviceModel"] boolValue]) flags |= kFlagModel;
    if ([prefs[@"IgnoreOSVersion"] boolValue])   flags |= kFlagOS;
    return flags;
}

static void CrossFamilyPost(CFStringRef name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         name, NULL, NULL, YES);
}

static void CrossFamilyPostState(unsigned int flags) {
    NSString *why = nil;
    BOOL ok = CrossFamilyWriteStateFile(flags, &why);
    // May fail once after an upgrade (root-owned file); the notifications still work
    NSLog(@"[CrossFamilyInstallPrefs] state file write (0x%x) -> %@ %@",
          flags, ok ? @"OK" : @"FAILED", why ?: @"");

    CrossFamilyPost((flags & kFlagFamily) ? CFSTR("com.soulrune.crossfamilyinstall/enable")
                                          : CFSTR("com.soulrune.crossfamilyinstall/disable"));
    CrossFamilyPost((flags & kFlagModel)  ? CFSTR("com.soulrune.crossfamilyinstall/model/enable")
                                          : CFSTR("com.soulrune.crossfamilyinstall/model/disable"));
    CrossFamilyPost((flags & kFlagOS)     ? CFSTR("com.soulrune.crossfamilyinstall/os/enable")
                                          : CFSTR("com.soulrune.crossfamilyinstall/os/disable"));
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

// Per-App Spoofing switches store into CFISpoofStore's draft ("spoof" = YES).
- (PSSpecifier *)spoofSwitchNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *s = [self switchSpecifierNamed:name key:key];
    [s setProperty:@YES forKey:@"spoof"];
    return s;
}

- (PSSpecifier *)linkNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL
                                                   detail:Nil cell:PSLinkCell edit:Nil];
    s->action = action;
    return s;
}

// A row that opens an app's spoofing page (the page reads "bid").
- (PSSpecifier *)appPageFor:(NSDictionary *)app {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:app[@"name"] target:self set:NULL get:NULL
                                                   detail:[CFIAppSpoofController class] cell:PSLinkCell edit:Nil];
    [s setProperty:app[@"id"] forKey:@"bid"];
    UIImage *icon = [CFISpoofStore iconForBundle:app[@"id"]];
    if (icon) {
        // Settings-row size, rounded like the app lists
        CGSize side = CGSizeMake(29, 29);
        icon = [[[UIGraphicsImageRenderer alloc] initWithSize:side] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side.width, side.height) cornerRadius:6.5] addClip];
            [icon drawInRect:CGRectMake(0, 0, side.width, side.height)];
        }];
        [s setProperty:icon forKey:@"iconImage"];
    }
    return s;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        // --- Installer (installd)
        [specs addObject:[self groupNamed:@"Installation"
                                    footer:@"Lets IPAs install past these checks. The app may still "
                                           @"crash if it really needs another device or newer iOS."]];
        [specs addObject:[self switchSpecifierNamed:@"Allow Other Device Family" key:@"Enabled"]];
        [specs addObject:[self switchSpecifierNamed:@"Ignore Device Model" key:@"IgnoreDeviceModel"]];
        [specs addObject:[self switchSpecifierNamed:@"Ignore iOS Version" key:@"IgnoreOSVersion"]];

        // --- Per-App Spoofing
        [specs addObject:[self groupNamed:@"Per-App Spoofing"
                                    footer:@"What chosen apps see: device, iOS, CPU, RAM, GPU. App Store: "
                                           @"its device and iOS also go to Apple with purchases, so apps "
                                           @"\"not supported on this device\" can be got."]];
        [specs addObject:[self spoofSwitchNamed:@"Enabled" key:@"Enabled"]];
        [specs addObject:[self linkNamed:@"Apps" action:@selector(openApps)]];
        for (NSDictionary *app in [CFISpoofStore storeApps]) [specs addObject:[self appPageFor:app]];
        [specs addObject:[self buttonNamed:@"Reset All Apps" action:@selector(resetSpoof)]];

        // --- The one Apply
        [specs addObject:[self groupNamed:@"" footer:@"Saves everything above and restarts installd. "
                                                    @"Spoofed apps pick it up on their next launch."]];
        [specs addObject:[self buttonNamed:@"Apply (Restart installd)" action:@selector(applySettings)]];

        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)openApps {
    [self.navigationController pushViewController:[CFIAppsTableController new] animated:YES];
}

- (void)resetSpoof {
    [CFISpoofListBase resetFrom:self done:^{
        self->_specifiers = nil;
        [self reloadSpecifiers];
    }];
}

#pragma mark - Preferences persistence


- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([[specifier propertyForKey:@"spoof"] boolValue]) {
        [CFISpoofStore setObject:value forKey:key];   // draft, live after Apply
        return;
    }
    NSString *path = CrossFamilyUIPrefsPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    prefs[key] = value;
    [prefs writeToFile:path atomically:YES];

    // This is what installd acts on; the plist only backs the switch
    CrossFamilyPostState(CrossFamilyFlagsFromPrefs(prefs));
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([[specifier propertyForKey:@"spoof"] boolValue]) {
        return @([[CFISpoofStore objectForKey:key] boolValue]);
    }
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:CrossFamilyUIPrefsPath()];
    return @([prefs[key] boolValue]);
}

#pragma mark - Apply (restart installd)
//
// Only posts a Darwin notification: the tweak inside installd exits on it and
// launchd starts installd again. No privileges needed from here.

// The one Apply: Per-App Spoofing (after its values are checked) and installd.
- (void)applySettings {
    [CFISpoofListBase checkFrom:self then:^{ [self commitAll]; }];
}

- (void)commitAll {
    // Per-App Spoofing: draft -> applied (+ appstored); apps read it on launch
    [CFISpoofStore apply];

    // installd: re-post the state, then restart it (clears its verdict cache)
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:CrossFamilyUIPrefsPath()];
    unsigned int flags = CrossFamilyFlagsFromPrefs(prefs);
    CrossFamilyPostState(flags);

    CrossFamilyPost(CFSTR("com.soulrune.crossfamilyinstall/restart"));

    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];

    [self toast:@"Applied"
        message:[NSString stringWithFormat:
                 @"installd restarted (family: %@, model: %@, iOS: %@). "
                 @"Spoofed apps pick their values up on their next launch.",
                 (flags & kFlagFamily) ? @"ignored" : @"checked",
                 (flags & kFlagModel)  ? @"ignored" : @"checked",
                 (flags & kFlagOS)     ? @"ignored" : @"checked"]];
}

- (void)toast:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
