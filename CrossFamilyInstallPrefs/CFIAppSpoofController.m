#import "CFIAppSpoofController.h"
#import "CFISpoofStore.h"
#import "CFISpoofPresets.h"

// Per-app page, two modes:
//   Simple   - family, device, iOS. Picking a device also sets its CPU, cores,
//              RAM and GPU (CFIDevices()).
//   Advanced - every value on its own, in the same order.
// Both edit the same keys, so switching modes keeps what's set.

@implementation CFIAppSpoofController

- (NSString *)bid {
    return [self.specifier propertyForKey:@"bid"] ?: @"";
}

- (NSString *)k:(NSString *)suffix {
    return [CFISpoofStore key:[self bid] suffix:suffix];
}

- (NSString *)value:(NSString *)suffix {
    id v = [CFISpoofStore objectForKey:[self k:suffix]];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

- (BOOL)advanced {
    return [[self value:@"Mode"] isEqualToString:@"advanced"];
}

// The App Store entries only get iOS versions newer than the device's own.
- (NSArray<NSArray<NSString *> *> *)osPresets {
    return [CFISpoofStore isStoreBundle:[self bid]] ? CFIStoreOSPresets() : CFIOSPresets();
}

- (PSSpecifier *)disable:(PSSpecifier *)s when:(BOOL)cond {
    if (cond) [s setProperty:@NO forKey:@"enabled"];
    return s;
}

// Preset picker for `key`. A typed value that isn't a preset is added as a
// "Custom" entry, so the row shows it instead of going blank.
- (PSSpecifier *)presetNamed:(NSString *)name key:(NSString *)key
                     presets:(NSArray<NSArray<NSString *> *> *)presets {
    NSMutableArray *values = [NSMutableArray array], *titles = [NSMutableArray array];
    for (NSArray<NSString *> *p in presets) {
        [values addObject:p[0]];
        [titles addObject:p[1]];
    }
    NSString *current = [CFISpoofStore objectForKey:key];
    if ([current isKindOfClass:[NSString class]] && current.length && ![values containsObject:current]) {
        [values addObject:current];
        [titles addObject:[NSString stringWithFormat:@"Custom (%@)", current]];
    }
    return [self choiceNamed:name key:key values:values titles:titles];
}

// Group with a footer that turns into a warning when the value would be ignored.
- (PSSpecifier *)groupNamed:(NSString *)title suffix:(NSString *)suffix footer:(NSString *)footer {
    NSString *value = [self value:suffix];
    NSString *problem = [CFISpoofStore problemWithValue:value suffix:suffix bundle:[self bid]];
    if (problem) footer = [NSString stringWithFormat:@"Warning: \"%@\" %@, ignored.", value, problem];
    return [self groupNamed:title footer:footer];
}

// Preset row + text field on one key.
- (void)addField:(NSString *)title suffix:(NSString *)suffix
         presets:(NSArray<NSArray<NSString *> *> *)presets label:(NSString *)label
          footer:(NSString *)footer off:(BOOL)off to:(NSMutableArray *)specs {
    [specs addObject:[self groupNamed:title suffix:suffix footer:footer]];
    [specs addObject:[self disable:[self presetNamed:@"Preset" key:[self k:suffix] presets:presets] when:off]];
    [specs addObject:[self disable:[self textNamed:label key:[self k:suffix] placeholder:@"real"] when:off]];
}

- (PSSpecifier *)familyRow:(BOOL)off {
    return [self disable:[self presetNamed:@"Family" key:[self k:@"Family"] presets:CFIFamilyPresets()] when:off];
}

- (void)addSimple:(NSMutableArray *)specs off:(BOOL)off {
    [specs addObject:[self groupNamed:@"Device" suffix:@"Model"
                               footer:@"The device also sets its CPU, cores, RAM and GPU."]];
    [specs addObject:[self familyRow:off]];
    PSSpecifier *device = [self presetNamed:@"Device" key:[self k:@"Model"]
                                    presets:CFIModelPresets([self value:@"Family"])];
    [device setProperty:@YES forKey:@"cfiDevice"];
    [specs addObject:[self disable:device when:off]];

    [specs addObject:[self groupNamed:@"iOS Version" suffix:@"OSVersion" footer:nil]];
    [specs addObject:[self disable:[self presetNamed:@"Version" key:[self k:@"OSVersion"]
                                             presets:[self osPresets]] when:off]];
}

- (void)addAdvanced:(NSMutableArray *)specs off:(BOOL)off {
    [specs addObject:[self groupNamed:@"Device Family" footer:@"UIDevice.userInterfaceIdiom."]];
    [specs addObject:[self familyRow:off]];
    [self addField:@"Device" suffix:@"Model" presets:CFIModelPresets([self value:@"Family"])
             label:@"Identifier" footer:@"hw.machine, uname, UIDevice.model." off:off to:specs];
    [self addField:@"iOS Version" suffix:@"OSVersion" presets:[self osPresets]
             label:@"Version" footer:@"UIDevice, NSProcessInfo. Not #available." off:off to:specs];
    [self addField:@"CPU" suffix:@"CPU" presets:CFICPUPresets()
             label:@"Name" footer:@"machdep.cpu.brand_string." off:off to:specs];
    [self addField:@"CPU Cores" suffix:@"CPUCores" presets:CFICoresPresets()
             label:@"Cores" footer:@"hw.ncpu, NSProcessInfo.processorCount." off:off to:specs];
    [self addField:@"RAM" suffix:@"Memory" presets:CFIMemoryPresets()
             label:@"MB" footer:@"Reported size only - iOS still closes the app at the real limit." off:off to:specs];
    [self addField:@"GPU" suffix:@"GPU" presets:CFIGPUPresets()
             label:@"Name" footer:@"Name only (MTLDevice.name), not what the GPU can do." off:off to:specs];
    [self addField:@"GPU Memory" suffix:@"GPUMemory" presets:CFIGPUMemoryPresets()
             label:@"MB" footer:@"MTLDevice.recommendedMaxWorkingSetSize, iOS 16+." off:off to:specs];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        NSString *bid = [self bid];
        BOOL off = ![CFISpoofStore appEnabled:bid];

        [specs addObject:[self groupNamed:bid footer:@"Only what you set is changed. Apply on the main page; "
                                                     @"the app picks it up on its next launch."]];
        [specs addObject:[self switchNamed:@"Enabled" key:[CFISpoofStore enableKey:bid]]];
        [specs addObject:[self choiceNamed:@"Mode" key:[self k:@"Mode"]
                                    values:@[@"", @"advanced"] titles:@[@"Simple", @"Advanced"]]];

        if ([self advanced]) [self addAdvanced:specs off:off];
        else                 [self addSimple:specs off:off];

        [specs addObject:[self groupNamed:@"" footer:nil]];
        [specs addObject:[self buttonNamed:@"Reset this app" action:@selector(resetThisApp)]];

        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)resetThisApp {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset this app?"
                                                              message:@"Clears its values. Apply on the main page afterwards."
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        [CFISpoofStore resetBundle:[self bid]];
        self->_specifiers = nil;
        [self reloadSpecifiers];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([[specifier propertyForKey:@"cfiDevice"] boolValue]) {
        // Simple mode's device: the whole hardware set of that device
        NSDictionary *device = CFIDeviceForModel(value);
        if (device || ![value length]) {
            [CFISpoofStore applyDevice:device toBundle:[self bid]];
        } else {
            [super setPreferenceValue:value specifier:specifier];   // a custom identifier
        }
    } else {
        [super setPreferenceValue:value specifier:specifier];
        // Simple mode: a device of the other family no longer fits
        if (![self advanced] && [key isEqualToString:[self k:@"Family"]]) {
            NSDictionary *device = CFIDeviceForModel([self value:@"Model"]);
            if (device && [value length] && ![device[@"family"] isEqualToString:value]) {
                [CFISpoofStore applyDevice:nil toBundle:[self bid]];
                [CFISpoofStore setObject:value forKey:key];
            }
        }
    }
    // Rows depend on each other (mode, family filter, warnings): rebuild them
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_specifiers = nil;
        [self reloadSpecifiers];
    });
}

@end
