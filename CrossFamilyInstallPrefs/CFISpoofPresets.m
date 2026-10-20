#import "CFISpoofPresets.h"

// Presets: { value, title }. "" == leave the real value alone.
// Any value can also be typed into the text field below the preset row.

// Device table for Simple mode. RAM is the nominal size: real devices report a
// little less (a 2 GB iPhone 8 says ~1975 MB). GPU names are exactly as Metal
// spells them (MTLDevice.name), which is what engines compare.
NSArray<NSDictionary<NSString *, NSString *> *> *CFIDevices(void) {
    static NSArray *devices;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *(^d)(NSString *, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *) =
            ^NSDictionary *(NSString *model, NSString *name, NSString *family, NSString *cpu,
                            NSString *cores, NSString *ram, NSString *gpu) {
                return @{ @"model": model, @"name": name, @"family": family, @"cpu": cpu,
                          @"cores": cores, @"ram": ram, @"gpu": gpu };
            };
        devices = @[
            d(@"iPhone10,1", @"iPhone 8",           @"iphone", @"Apple A11 Bionic", @"6", @"2048", @"Apple A11 GPU"),
            d(@"iPhone10,3", @"iPhone X",           @"iphone", @"Apple A11 Bionic", @"6", @"3072", @"Apple A11 GPU"),
            d(@"iPhone11,2", @"iPhone XS",          @"iphone", @"Apple A12 Bionic", @"6", @"4096", @"Apple A12 GPU"),
            d(@"iPhone11,8", @"iPhone XR",          @"iphone", @"Apple A12 Bionic", @"6", @"3072", @"Apple A12 GPU"),
            d(@"iPhone12,1", @"iPhone 11",          @"iphone", @"Apple A13 Bionic", @"6", @"4096", @"Apple A13 GPU"),
            d(@"iPhone13,2", @"iPhone 12",          @"iphone", @"Apple A14 Bionic", @"6", @"4096", @"Apple A14 GPU"),
            d(@"iPhone14,5", @"iPhone 13",          @"iphone", @"Apple A15 Bionic", @"6", @"4096", @"Apple A15 GPU"),
            d(@"iPhone14,2", @"iPhone 13 Pro",      @"iphone", @"Apple A15 Bionic", @"6", @"6144", @"Apple A15 GPU"),
            d(@"iPhone14,7", @"iPhone 14",          @"iphone", @"Apple A15 Bionic", @"6", @"6144", @"Apple A15 GPU"),
            d(@"iPhone15,2", @"iPhone 14 Pro",      @"iphone", @"Apple A16 Bionic", @"6", @"6144", @"Apple A16 GPU"),
            d(@"iPhone15,4", @"iPhone 15",          @"iphone", @"Apple A16 Bionic", @"6", @"6144", @"Apple A16 GPU"),
            d(@"iPhone16,1", @"iPhone 15 Pro",      @"iphone", @"Apple A17 Pro",    @"6", @"8192", @"Apple A17 Pro GPU"),
            d(@"iPhone16,2", @"iPhone 15 Pro Max",  @"iphone", @"Apple A17 Pro",    @"6", @"8192", @"Apple A17 Pro GPU"),
            d(@"iPhone17,3", @"iPhone 16",          @"iphone", @"Apple A18",        @"6", @"8192", @"Apple A18 GPU"),
            d(@"iPhone17,1", @"iPhone 16 Pro",      @"iphone", @"Apple A18 Pro",    @"6", @"8192", @"Apple A18 Pro GPU"),
            d(@"iPhone17,2", @"iPhone 16 Pro Max",  @"iphone", @"Apple A18 Pro",    @"6", @"8192", @"Apple A18 Pro GPU"),
            d(@"iPad12,1",   @"iPad (9th gen)",     @"ipad",   @"Apple A13 Bionic", @"6", @"3072", @"Apple A13 GPU"),
            d(@"iPad13,18",  @"iPad (10th gen)",    @"ipad",   @"Apple A14 Bionic", @"6", @"4096", @"Apple A14 GPU"),
            d(@"iPad14,1",   @"iPad mini (6th gen)", @"ipad",  @"Apple A15 Bionic", @"6", @"4096", @"Apple A15 GPU"),
            d(@"iPad13,1",   @"iPad Air (4th gen)", @"ipad",   @"Apple A14 Bionic", @"6", @"4096", @"Apple A14 GPU"),
            d(@"iPad13,16",  @"iPad Air (5th gen)", @"ipad",   @"Apple M1",         @"8", @"8192", @"Apple M1 GPU"),
            d(@"iPad13,4",   @"iPad Pro 11\" (3rd gen)", @"ipad", @"Apple M1",      @"8", @"8192", @"Apple M1 GPU"),
            d(@"iPad14,3",   @"iPad Pro 11\" (4th gen)", @"ipad", @"Apple M2",      @"8", @"8192", @"Apple M2 GPU"),
        ];
    });
    return devices;
}

NSDictionary<NSString *, NSString *> *CFIDeviceForModel(NSString *model) {
    if (!model.length) return nil;
    for (NSDictionary *device in CFIDevices()) {
        if ([device[@"model"] isEqualToString:model]) return device;
    }
    return nil;
}

NSArray<NSArray<NSString *> *> *CFIModelPresets(NSString *family) {
    NSMutableArray *presets = [NSMutableArray arrayWithObject:@[@"", @"Real device"]];
    for (NSDictionary *device in CFIDevices()) {
        if (family.length && ![device[@"family"] isEqualToString:family]) continue;
        [presets addObject:@[device[@"model"], device[@"name"]]];
    }
    return presets;
}

NSArray<NSArray<NSString *> *> *CFIFamilyPresets(void) {
    return @[ @[@"", @"Real device"], @[@"iphone", @"iPhone"], @[@"ipad", @"iPad"] ];
}

NSArray<NSArray<NSString *> *> *CFIOSPresets(void) {
    return @[
        @[@"",     @"Real version"],
        @[@"15.8", @"iOS 15.8"],
        @[@"16.7", @"iOS 16.7"],
        @[@"17.0", @"iOS 17.0"],
        @[@"17.6", @"iOS 17.6"],
        @[@"18.0", @"iOS 18.0"],
        @[@"18.6", @"iOS 18.6"],
        @[@"26.0", @"iOS 26.0"],
    ];
}

BOOL CFIOSVersionIsNewerThanReal(NSString *version) {
    NSArray<NSString *> *parts = [version componentsSeparatedByString:@"."];
    if (!version.length || parts.count > 3) return NO;
    NSInteger v[3] = {0, 0, 0};
    for (NSUInteger i = 0; i < parts.count; i++) v[i] = parts[i].integerValue;
    // The settings app isn't spoofed, so this is the device's real version
    NSOperatingSystemVersion real = [[NSProcessInfo processInfo] operatingSystemVersion];
    NSInteger r[3] = {real.majorVersion, real.minorVersion, real.patchVersion};
    for (int i = 0; i < 3; i++) {
        if (v[i] != r[i]) return v[i] > r[i];
    }
    return NO;   // equal is not newer
}

NSArray<NSArray<NSString *> *> *CFIStoreOSPresets(void) {
    NSMutableArray *presets = [NSMutableArray array];
    for (NSArray<NSString *> *p in CFIOSPresets()) {
        if (!p[0].length || CFIOSVersionIsNewerThanReal(p[0])) [presets addObject:p];
    }
    return presets;
}

// Every distinct value of one device-table key, in table order, after "real".
static NSArray<NSArray<NSString *> *> *CFIPresetsFromDevices(NSString *key, NSString *realTitle) {
    NSMutableArray *presets = [NSMutableArray arrayWithObject:@[@"", realTitle]];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *device in CFIDevices()) {
        NSString *value = device[key];
        if ([seen containsObject:value]) continue;
        [seen addObject:value];
        [presets addObject:@[value, value]];
    }
    return presets;
}

NSArray<NSArray<NSString *> *> *CFICPUPresets(void) { return CFIPresetsFromDevices(@"cpu", @"Real CPU"); }
NSArray<NSArray<NSString *> *> *CFIGPUPresets(void) { return CFIPresetsFromDevices(@"gpu", @"Real GPU"); }

NSArray<NSArray<NSString *> *> *CFICoresPresets(void) {
    return @[
        @[@"",   @"Real count"],
        @[@"4",  @"4 cores"],
        @[@"6",  @"6 cores"],
        @[@"8",  @"8 cores"],
        @[@"10", @"10 cores"],
    ];
}

NSArray<NSArray<NSString *> *> *CFIMemoryPresets(void) {
    return @[
        @[@"",      @"Real memory"],
        @[@"3072",  @"3 GB"],
        @[@"4096",  @"4 GB"],
        @[@"6144",  @"6 GB"],
        @[@"8192",  @"8 GB"],
        @[@"12288", @"12 GB"],
        @[@"16384", @"16 GB"],
    ];
}

NSArray<NSArray<NSString *> *> *CFIGPUMemoryPresets(void) {
    return @[
        @[@"",     @"Real value"],
        @[@"2048", @"2 GB"],
        @[@"4096", @"4 GB"],
        @[@"6144", @"6 GB"],
        @[@"8192", @"8 GB"],
    ];
}
