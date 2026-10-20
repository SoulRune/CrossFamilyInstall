#import "CFISpoofStore.h"
#import "CFISpoofPresets.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kDraftDomain   = @"com.soulrune.crossfamilyinstall.spoof";
static NSString *const kAppliedDomain = @"com.soulrune.crossfamilyinstall.spoof.applied";   // read by Spoof.xm

// Minimal private API surface for enumerating installed apps.
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;   // "User" / "System" / ...
@property (nonatomic, readonly) NSArray *appTags;            // contains "hidden" for invisible apps
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

// Optional: AppList's visible-apps filter and icons when it's installed,
// LaunchServices and UIImage's private icon API otherwise.
@interface ALApplicationList : NSObject
+ (instancetype)sharedApplicationList;
- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate
                                         onlyVisible:(BOOL)onlyVisible
                              titleSortedIdentifiers:(NSArray **)outIdentifiers;
- (UIImage *)iconOfSize:(int)iconSize forDisplayIdentifier:(NSString *)displayIdentifier;
@end

@implementation CFISpoofStore

#pragma mark - Paths

+ (NSString *)pathForDomain:(NSString *)domain {
    NSString *root = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"/var/jb" : @"";
    return [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/%@.plist", root, domain];
}
+ (NSString *)draftPath   { return [self pathForDomain:kDraftDomain]; }
+ (NSString *)appliedPath { return [self pathForDomain:kAppliedDomain]; }

#pragma mark - Draft access

+ (id)objectForKey:(NSString *)key {
    if (!key) return nil;
    return [NSDictionary dictionaryWithContentsOfFile:[self draftPath]][key];
}

+ (void)setObject:(id)value forKey:(NSString *)key {
    if (!key) return;
    if ([value isKindOfClass:[NSString class]]) {
        value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([value length] == 0) value = nil;
    }
    NSString *path = [self draftPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    [d writeToFile:path atomically:YES];
}

+ (NSString *)enableKey:(NSString *)bid { return [@"enabled-" stringByAppendingString:bid]; }
+ (NSString *)key:(NSString *)bid suffix:(NSString *)suffix {
    return [NSString stringWithFormat:@"%@-%@", bid, suffix];
}
+ (BOOL)appEnabled:(NSString *)bid { return [[self objectForKey:[self enableKey:bid]] boolValue]; }
+ (void)setAppEnabled:(BOOL)value forBundle:(NSString *)bid {
    [self setObject:@(value) forKey:[self enableKey:bid]];
}

+ (NSArray<NSString *> *)valueSuffixes {
    return @[@"Family", @"Model", @"OSVersion", @"CPU", @"CPUCores", @"Memory", @"GPU", @"GPUMemory"];
}

+ (void)applyDevice:(NSDictionary<NSString *, NSString *> *)device toBundle:(NSString *)bid {
    if (!bid.length) return;
    NSDictionary *keys = @{ @"Family": @"family", @"Model": @"model", @"CPU": @"cpu",
                            @"CPUCores": @"cores", @"Memory": @"ram", @"GPU": @"gpu" };
    NSString *path = [self draftPath];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    for (NSString *suffix in keys) {
        NSString *value = device[keys[suffix]];
        NSString *key = [self key:bid suffix:suffix];
        if (value.length) d[key] = value; else [d removeObjectForKey:key];
    }
    [d writeToFile:path atomically:YES];
}

+ (void)resetBundle:(NSString *)bid {
    if (!bid.length) return;
    NSString *path = [self draftPath];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) return;
    [d removeObjectForKey:[self enableKey:bid]];
    for (NSString *suffix in [self valueSuffixes]) [d removeObjectForKey:[self key:bid suffix:suffix]];
    [d removeObjectForKey:[self key:bid suffix:@"Mode"]];
    [d writeToFile:path atomically:YES];
}

+ (NSString *)summaryForBundle:(NSString *)bid {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self draftPath]];
    NSString *(^v)(NSString *) = ^NSString *(NSString *suffix) {
        id value = d[[self key:bid suffix:suffix]];
        return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
    };
    NSMutableArray *parts = [NSMutableArray array];
    NSString *family = v(@"Family"), *model = v(@"Model");
    if (model)                                      [parts addObject:CFIDeviceForModel(model)[@"name"] ?: model];
    else if ([family isEqualToString:@"ipad"])      [parts addObject:@"iPad"];
    else if ([family isEqualToString:@"iphone"])    [parts addObject:@"iPhone"];
    if (v(@"OSVersion")) [parts addObject:[@"iOS " stringByAppendingString:v(@"OSVersion")]];
    if (v(@"CPU"))       [parts addObject:v(@"CPU")];
    if (v(@"CPUCores"))  [parts addObject:[v(@"CPUCores") stringByAppendingString:@" cores"]];
    if (v(@"Memory"))    [parts addObject:[v(@"Memory") stringByAppendingString:@" MB"]];
    if (v(@"GPU"))       [parts addObject:v(@"GPU")];
    if (v(@"GPUMemory")) [parts addObject:[v(@"GPUMemory") stringByAppendingString:@" MB GPU"]];
    return parts.count ? [parts componentsJoinedByString:@", "] : nil;
}

#pragma mark - Validation

+ (BOOL)matches:(NSString *)s pattern:(NSString *)pattern {
    if (![s isKindOfClass:[NSString class]] || !s.length) return NO;
    return [s rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}
+ (BOOL)isValidModel:(NSString *)model {
    return model.length < 64 && [self matches:model pattern:@"^[A-Za-z]+[0-9]+,[0-9]+$"];
}
+ (BOOL)isValidOSVersion:(NSString *)version {
    return [self matches:version pattern:@"^[1-9][0-9]{0,2}(\\.[0-9]{1,3}){0,2}$"];
}
// Same rules as Spoof.xm: whole numbers in range
+ (BOOL)isNumber:(NSString *)s min:(long long)min max:(long long)max {
    if (![self matches:s pattern:@"^[0-9]{1,7}$"]) return NO;
    long long v = s.longLongValue;
    return v >= min && v <= max;
}
+ (BOOL)isValidMemory:(NSString *)mb    { return [self isNumber:mb min:256 max:1048576]; }
+ (BOOL)isValidGPUMemory:(NSString *)mb { return [self isNumber:mb min:64 max:1048576]; }
+ (BOOL)isValidCores:(NSString *)cores  { return [self isNumber:cores min:1 max:64]; }
+ (BOOL)isValidGPUName:(NSString *)name {
    return name.length <= 63 && [self matches:name pattern:@"^[ -~]+$"];
}
+ (BOOL)isValidCPUName:(NSString *)name { return [self isValidGPUName:name]; }

+ (NSString *)problemWithValue:(NSString *)v suffix:(NSString *)suffix {
    if (![v isKindOfClass:[NSString class]] || !v.length) return nil;
    if ([suffix isEqualToString:@"Model"])     return [self isValidModel:v]     ? nil : @"isn't a model identifier (like iPad13,16)";
    if ([suffix isEqualToString:@"OSVersion"]) return [self isValidOSVersion:v] ? nil : @"isn't a version (like 17.0 or 17.4.1)";
    if ([suffix isEqualToString:@"Memory"])    return [self isValidMemory:v]    ? nil : @"isn't a RAM size in MB (256 - 1048576)";
    if ([suffix isEqualToString:@"GPUMemory"]) return [self isValidGPUMemory:v] ? nil : @"isn't a GPU memory size in MB (64 - 1048576)";
    if ([suffix isEqualToString:@"CPUCores"])  return [self isValidCores:v]     ? nil : @"isn't a core count (1 - 64)";
    if ([suffix isEqualToString:@"GPU"])       return [self isValidGPUName:v]   ? nil : @"isn't a GPU name (plain ASCII, up to 63 characters)";
    if ([suffix isEqualToString:@"CPU"])       return [self isValidCPUName:v]   ? nil : @"isn't a CPU name (plain ASCII, up to 63 characters)";
    return nil;
}

+ (BOOL)isStoreBundle:(NSString *)bid {
    return [bid isEqualToString:@"com.apple.AppStore"] || [bid isEqualToString:@"com.apple.ios.StoreKitUIService"];
}

+ (NSString *)problemWithValue:(NSString *)v suffix:(NSString *)suffix bundle:(NSString *)bid {
    NSString *problem = [self problemWithValue:v suffix:suffix];
    if (problem) return problem;
    // Apple's store refuses an iOS version that isn't newer than the real one
    if ([self isStoreBundle:bid] && [suffix isEqualToString:@"OSVersion"] &&
        [v isKindOfClass:[NSString class]] && v.length && !CFIOSVersionIsNewerThanReal(v)) {
        return @"isn't newer than this device's iOS - the App Store would refuse the sign-in";
    }
    return nil;
}

#pragma mark - App enumeration

+ (NSArray<NSDictionary *> *)userApps {
    LSApplicationWorkspace *ws = [objc_getClass("LSApplicationWorkspace") defaultWorkspace];
    NSMutableDictionary<NSString *, NSString *> *typeOf = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *nameOf = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *hidden = [NSMutableSet set];
    for (LSApplicationProxy *app in [ws allApplications]) {
        NSString *bid = app.applicationIdentifier;
        if (!bid.length) continue;
        typeOf[bid] = app.applicationType ?: @"System";
        nameOf[bid] = app.localizedName ?: bid;
        @try {
            if ([app respondsToSelector:@selector(appTags)] && [app.appTags containsObject:@"hidden"]) [hidden addObject:bid];
        } @catch (__unused NSException *e) {}
    }

    NSArray *candidateIds = nil;
    ALApplicationList *al = [objc_getClass("ALApplicationList") sharedApplicationList];
    SEL sel = @selector(applicationsFilteredUsingPredicate:onlyVisible:titleSortedIdentifiers:);
    if ([al respondsToSelector:sel]) {
        @try {
            NSArray *sortedIds = nil;
            NSDictionary *apps = [al applicationsFilteredUsingPredicate:[NSPredicate predicateWithValue:YES]
                                                            onlyVisible:YES
                                                 titleSortedIdentifiers:&sortedIds];
            candidateIds = sortedIds.count ? sortedIds : apps.allKeys;
            for (NSString *bid in apps) if (!nameOf[bid]) nameOf[bid] = apps[bid] ?: bid;
        } @catch (__unused NSException *e) {}
    }
    if (candidateIds.count == 0) {
        // No AppList: everything LaunchServices knows, minus apps tagged hidden.
        NSMutableArray *ids = [typeOf.allKeys mutableCopy];
        [ids removeObjectsInArray:hidden.allObjects];
        candidateIds = ids;
    }

    NSMutableArray *result = [NSMutableArray array];
    for (NSString *bid in candidateIds) {
        if (![typeOf[bid] isEqualToString:@"User"]) continue;
        [result addObject:@{ @"id": bid, @"name": nameOf[bid] ?: bid }];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return result;
}

+ (NSArray<NSDictionary *> *)storeApps {
    NSDictionary<NSString *, NSString *> *wanted = @{
        @"com.apple.AppStore": @"App Store",
        @"com.apple.ios.StoreKitUIService": @"App Store sheets (in other apps)",
    };
    NSMutableArray *result = [NSMutableArray array];
    LSApplicationWorkspace *ws = [objc_getClass("LSApplicationWorkspace") defaultWorkspace];
    for (LSApplicationProxy *app in [ws allApplications]) {
        NSString *bid = app.applicationIdentifier;
        if (bid && wanted[bid]) [result addObject:@{ @"id": bid, @"name": wanted[bid] }];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    return result;
}

#pragma mark - Icons

+ (UIImage *)iconForBundle:(NSString *)bid {
    if (!bid.length) return nil;
    ALApplicationList *al = [objc_getClass("ALApplicationList") sharedApplicationList];
    if ([al respondsToSelector:@selector(iconOfSize:forDisplayIdentifier:)]) {
        @try {
            UIImage *img = [al iconOfSize:29 forDisplayIdentifier:bid];
            if (img) return img;
        } @catch (__unused NSException *e) {}
    }
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:s]) {
        CGFloat scale = [UIScreen mainScreen].scale;
        UIImage *img = ((UIImage *(*)(id, SEL, NSString *, int, CGFloat))objc_msgSend)([UIImage class], s, bid, 2, scale);
        if (img) return img;
    }
    return nil;
}

#pragma mark - Commit / reset

// appstored reads the App Store entry from cfprefsd and reloads it on the
// notification (see Spoof.xm).
+ (void)publishStoreDaemonValues:(NSDictionary *)applied {
    CFStringRef domain = CFSTR("com.soulrune.crossfamilyinstall.store");
    NSString *bid = @"com.apple.AppStore";
    BOOL on = [applied[@"Enabled"] boolValue] && [applied[[self enableKey:bid]] boolValue];
    CFPreferencesSetAppValue(CFSTR("Enabled"), on ? kCFBooleanTrue : kCFBooleanFalse, domain);
    for (NSString *suffix in @[@"OSVersion", @"Model"]) {
        id value = on ? applied[[self key:bid suffix:suffix]] : nil;
        CFPreferencesSetAppValue((__bridge CFStringRef)suffix,
                                 [value isKindOfClass:[NSString class]] ? (__bridge CFPropertyListRef)value : NULL,
                                 domain);
    }
    CFPreferencesAppSynchronize(domain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.soulrune.crossfamilyinstall/store/reload"), NULL, NULL, YES);
}

+ (void)apply {
    NSDictionary *draft = [NSDictionary dictionaryWithContentsOfFile:[self draftPath]] ?: @{};
    [draft writeToFile:[self appliedPath] atomically:YES];
    [self publishStoreDaemonValues:draft];
}

+ (void)resetAll {
    [[NSFileManager defaultManager] removeItemAtPath:[self draftPath] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[self appliedPath] error:nil];
    [self publishStoreDaemonValues:@{}];
}

@end
