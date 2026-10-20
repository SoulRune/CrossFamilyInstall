#import <Foundation/Foundation.h>

// Presets shared by the per-app page and the bulk editor.
// Each entry is @[ value, title ]; the first entry ("" == real) comes first.

// One known device: what Simple mode fills in when it's picked.
// Keys: model, name, family ("iphone"/"ipad"), cpu, cores, ram (MB), gpu.
NSArray<NSDictionary<NSString *, NSString *> *> *CFIDevices(void);
// The device with this model identifier, or nil.
NSDictionary<NSString *, NSString *> *CFIDeviceForModel(NSString *model);

// Devices of one family ("iphone"/"ipad"; nil or "" == all), as presets.
NSArray<NSArray<NSString *> *> *CFIModelPresets(NSString *family);
NSArray<NSArray<NSString *> *> *CFIFamilyPresets(void);
NSArray<NSArray<NSString *> *> *CFIOSPresets(void);
// For the App Store entries: only versions newer than the device's own, since
// the store refuses a lower one.
NSArray<NSArray<NSString *> *> *CFIStoreOSPresets(void);
// YES for "x[.y[.z]]" newer than the real iOS of this device.
BOOL CFIOSVersionIsNewerThanReal(NSString *version);
NSArray<NSArray<NSString *> *> *CFICPUPresets(void);         // machdep.cpu.brand_string
NSArray<NSArray<NSString *> *> *CFICoresPresets(void);
NSArray<NSArray<NSString *> *> *CFIMemoryPresets(void);      // RAM, MB
NSArray<NSArray<NSString *> *> *CFIGPUPresets(void);         // MTLDevice.name
NSArray<NSArray<NSString *> *> *CFIGPUMemoryPresets(void);   // MB
