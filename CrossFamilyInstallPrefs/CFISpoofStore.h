#import <UIKit/UIKit.h>

// Storage and app list for Per-App Spoofing. The panel edits a draft plist;
// +apply copies it to the applied one, which Spoof.xm reads at app launch.
//
// Keys:
//   Enabled                 BOOL    master switch for the whole section
//   enabled-<bid>           BOOL    this app is spoofed
//   <bid>-Model             string  "iPad13,16"           (absent = real)
//   <bid>-Family            string  "iphone" / "ipad"     (absent = real)
//   <bid>-OSVersion         string  "17.0"                (absent = real)
//   <bid>-Mode              string  "advanced" (absent = simple; the page only)
//   <bid>-CPU               string  "Apple A16 Bionic"    (absent = real)
//   <bid>-CPUCores          string  "6"                   (absent = real)
//   <bid>-Memory            string  RAM in MB, "6144"     (absent = real)
//   <bid>-GPU               string  "Apple A16 GPU"       (absent = real)
//   <bid>-GPUMemory         string  GPU memory in MB      (absent = real)
@interface CFISpoofStore : NSObject

+ (NSString *)draftPath;
+ (NSString *)appliedPath;

// Draft access. Setting nil or an empty/whitespace string removes the key.
+ (id)objectForKey:(NSString *)key;
+ (void)setObject:(id)value forKey:(NSString *)key;

+ (NSString *)enableKey:(NSString *)bid;
+ (NSString *)key:(NSString *)bid suffix:(NSString *)suffix;
+ (BOOL)appEnabled:(NSString *)bid;
+ (void)setAppEnabled:(BOOL)value forBundle:(NSString *)bid;

// Value suffixes stored per app, in page order.
+ (NSArray<NSString *> *)valueSuffixes;
// Sets family, model, CPU, cores, RAM and GPU from a CFIDevices() entry;
// nil clears them (GPU memory and iOS version are left alone).
+ (void)applyDevice:(NSDictionary<NSString *, NSString *> *)device toBundle:(NSString *)bid;
// Clears the app's flag and values from the draft.
+ (void)resetBundle:(NSString *)bid;

// "iPad Air (5th gen), iOS 17.0" for an app's current draft values, or nil.
+ (NSString *)summaryForBundle:(NSString *)bid;

// Visible user apps (App Store and sideloaded), name-sorted:
// @[ @{ @"id": bundleID, @"name": displayName } ].
+ (NSArray<NSDictionary *> *)userApps;
+ (UIImage *)iconForBundle:(NSString *)bid;
// App Store and StoreKit's product sheets, those installed. Same format.
+ (NSArray<NSDictionary *> *)storeApps;

// Validation shared with the UI (the tweak re-validates on its side).
+ (BOOL)isValidModel:(NSString *)model;
+ (BOOL)isValidOSVersion:(NSString *)version;
+ (BOOL)isValidMemory:(NSString *)mb;        // 256 ... 1048576
+ (BOOL)isValidGPUMemory:(NSString *)mb;     // 64 ... 1048576
+ (BOOL)isValidCores:(NSString *)cores;      // 1 ... 64
+ (BOOL)isValidGPUName:(NSString *)name;     // printable ASCII, up to 63 chars
+ (BOOL)isValidCPUName:(NSString *)name;     // same rules
// Short reason a set value would be ignored by the tweak, or nil if it's fine.
+ (NSString *)problemWithValue:(NSString *)value suffix:(NSString *)suffix;
// The same, plus per-app rules (App Store entries need an iOS newer than the real one).
+ (NSString *)problemWithValue:(NSString *)value suffix:(NSString *)suffix bundle:(NSString *)bid;
// App Store and StoreKit's product sheets.
+ (BOOL)isStoreBundle:(NSString *)bid;

+ (void)apply;      // draft -> applied
+ (void)resetAll;   // wipe draft + applied

@end
