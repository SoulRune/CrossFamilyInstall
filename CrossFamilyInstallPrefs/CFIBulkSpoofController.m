#import "CFIBulkSpoofController.h"
#import "CFISpoofStore.h"
#import "CFISpoofPresets.h"

// Rows of the "Values" section, in order. Each maps to a CFISpoofStore suffix.
// Device is a shortcut, like Simple mode: it picks the family, model, CPU,
// cores, RAM and GPU of a known device at once.
typedef NS_ENUM(NSInteger, CFIBulkField) {
    CFIBulkFieldDevice = 0,
    CFIBulkFieldFamily,
    CFIBulkFieldModel,
    CFIBulkFieldOS,
    CFIBulkFieldCPU,
    CFIBulkFieldCores,
    CFIBulkFieldMemory,
    CFIBulkFieldGPU,
    CFIBulkFieldGPUMemory,
    CFIBulkFieldCount
};

enum { kSectionEnabled = 0, kSectionValues, kSectionApply, kSectionCount };

@interface CFIBulkSpoofController ()
@property (nonatomic, copy) NSArray<NSString *> *bundleIDs;
@property (nonatomic) BOOL enabledState;
// Per field: nil == keep each app's current value, @"" == real, else the value.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *choices;
@end

@implementation CFIBulkSpoofController

- (instancetype)initWithBundleIDs:(NSArray<NSString *> *)bundleIDs {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _bundleIDs = [bundleIDs copy];
        _enabledState = YES;
        _choices = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"%lu apps", (unsigned long)self.bundleIDs.count];
}

#pragma mark - Field helpers

// With an App Store entry selected, only iOS versions newer than the device's own.
- (BOOL)hasStoreApp {
    for (NSString *bid in self.bundleIDs) {
        if ([CFISpoofStore isStoreBundle:bid]) return YES;
    }
    return NO;
}

// The strictest check among the selected apps.
- (NSString *)problemWithValue:(NSString *)v suffix:(NSString *)suffix {
    for (NSString *bid in self.bundleIDs) {
        NSString *problem = [CFISpoofStore problemWithValue:v suffix:suffix bundle:bid];
        if (problem) return problem;
    }
    return [CFISpoofStore problemWithValue:v suffix:suffix];
}

- (NSString *)suffixFor:(CFIBulkField)f {
    switch (f) {
        case CFIBulkFieldDevice:    return nil;
        case CFIBulkFieldModel:     return @"Model";
        case CFIBulkFieldFamily:    return @"Family";
        case CFIBulkFieldOS:        return @"OSVersion";
        case CFIBulkFieldCPU:       return @"CPU";
        case CFIBulkFieldMemory:    return @"Memory";
        case CFIBulkFieldCores:     return @"CPUCores";
        case CFIBulkFieldGPU:       return @"GPU";
        default:                    return @"GPUMemory";
    }
}

- (NSString *)titleFor:(CFIBulkField)f {
    switch (f) {
        case CFIBulkFieldDevice:    return @"Device (all hardware)";
        case CFIBulkFieldModel:     return @"Device Model";
        case CFIBulkFieldFamily:    return @"Device Family";
        case CFIBulkFieldOS:        return @"iOS Version";
        case CFIBulkFieldCPU:       return @"CPU";
        case CFIBulkFieldMemory:    return @"RAM";
        case CFIBulkFieldCores:     return @"CPU Cores";
        case CFIBulkFieldGPU:       return @"GPU";
        default:                    return @"GPU Memory";
    }
}

// Preset list of a field; the first entry is "real".
- (NSArray<NSArray<NSString *> *> *)presetsFor:(CFIBulkField)f {
    switch (f) {
        case CFIBulkFieldDevice:
        case CFIBulkFieldModel:     return CFIModelPresets(nil);
        case CFIBulkFieldFamily:    return CFIFamilyPresets();
        case CFIBulkFieldOS:        return [self hasStoreApp] ? CFIStoreOSPresets() : CFIOSPresets();
        case CFIBulkFieldCPU:       return CFICPUPresets();
        case CFIBulkFieldMemory:    return CFIMemoryPresets();
        case CFIBulkFieldCores:     return CFICoresPresets();
        case CFIBulkFieldGPU:       return CFIGPUPresets();
        default:                    return CFIGPUMemoryPresets();
    }
}

// What a field's row shows on the right.
- (NSString *)displayFor:(CFIBulkField)f {
    NSString *v = self.choices[@(f)];
    if (!v) return @"Keep current";
    if (!v.length) return [self presetsFor:f].firstObject[1];
    if (f == CFIBulkFieldDevice || f == CFIBulkFieldModel) return CFIDeviceForModel(v)[@"name"] ?: v;
    if (f == CFIBulkFieldFamily) return [v isEqualToString:@"ipad"] ? @"iPad" : @"iPhone";
    if (f == CFIBulkFieldOS) return [@"iOS " stringByAppendingString:v];
    if (f == CFIBulkFieldMemory || f == CFIBulkFieldGPUMemory) return [v stringByAppendingString:@" MB"];
    if (f == CFIBulkFieldCores) return [v stringByAppendingString:@" cores"];
    return v;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return kSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == kSectionValues ? CFIBulkFieldCount : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == kSectionValues ? @"Values" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == kSectionEnabled) return nil;
    if (section == kSectionValues)  return @"Only the fields you change are written.";
    return @"Apply on the main page afterwards.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSectionEnabled) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"sw"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"sw"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"Enabled";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = self.enabledState;
        [sw addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }
    if (indexPath.section == kSectionValues) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"val"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"val"];
        CFIBulkField f = (CFIBulkField)indexPath.row;
        cell.textLabel.text = [self titleFor:f];
        cell.detailTextLabel.text = [self displayFor:f];
        cell.detailTextLabel.textColor = self.choices[@(f)] ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];
        // Values only matter when enabling.
        cell.textLabel.enabled = self.enabledState;
        cell.userInteractionEnabled = self.enabledState;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"apply"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"apply"];
    cell.textLabel.text = [NSString stringWithFormat:@"Set on %lu apps", (unsigned long)self.bundleIDs.count];
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    return cell;
}

- (void)enabledChanged:(UISwitch *)sw {
    self.enabledState = sw.isOn;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kSectionValues]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kSectionValues) {
        [self pickValueFor:(CFIBulkField)indexPath.row from:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.section == kSectionApply) {
        [self commit];
    }
}

#pragma mark - Picking values

- (void)setChoice:(NSString *)value for:(CFIBulkField)f {
    if (value) self.choices[@(f)] = value; else [self.choices removeObjectForKey:@(f)];
    if (f == CFIBulkFieldDevice && value) {
        // "" (real) clears them all; a device sets them from its table entry
        NSDictionary *device = CFIDeviceForModel(value);
        NSDictionary<NSNumber *, NSString *> *fields = @{
            @(CFIBulkFieldFamily): @"family", @(CFIBulkFieldModel): @"model", @(CFIBulkFieldCPU): @"cpu",
            @(CFIBulkFieldCores): @"cores", @(CFIBulkFieldMemory): @"ram", @(CFIBulkFieldGPU): @"gpu",
        };
        for (NSNumber *field in fields) self.choices[field] = device[fields[field]] ?: @"";
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kSectionValues]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)pickValueFor:(CFIBulkField)f from:(UIView *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[self titleFor:f] message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Keep current" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [ws setChoice:nil for:f]; }]];

    for (NSArray<NSString *> *o in [self presetsFor:f]) {
        NSString *value = o[0];
        NSString *title = ((f == CFIBulkFieldModel || f == CFIBulkFieldDevice) && value.length)
            ? [NSString stringWithFormat:@"%@ (%@)", o[1], value] : o[1];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [ws setChoice:value for:f]; }]];
    }
    if (f != CFIBulkFieldFamily && f != CFIBulkFieldDevice) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Custom..." style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) { [ws promptCustomFor:f]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    // Required on iPad, where an action sheet is a popover.
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = source ? source.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Hint and example for a field's "Custom..." prompt.
- (NSArray<NSString *> *)customHintFor:(CFIBulkField)f {
    switch (f) {
        case CFIBulkFieldModel:     return @[@"Model identifier, e.g. iPad13,16", @"iPad13,16"];
        case CFIBulkFieldOS:        return @[@"Version, e.g. 17.0 or 17.4.1", @"17.0"];
        case CFIBulkFieldCPU:       return @[@"CPU name, e.g. Apple A16 Bionic", @"Apple A16 Bionic"];
        case CFIBulkFieldMemory:    return @[@"RAM in MB, e.g. 6144", @"6144"];
        case CFIBulkFieldCores:     return @[@"Number of CPU cores, e.g. 6", @"6"];
        case CFIBulkFieldGPU:       return @[@"GPU name as Metal reports it, e.g. Apple A16 GPU", @"Apple A16 GPU"];
        default:                    return @[@"GPU memory in MB, e.g. 4096", @"4096"];
    }
}

- (void)promptCustomFor:(CFIBulkField)f {
    NSArray<NSString *> *hint = [self customHintFor:f];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[self titleFor:f]
                                                              message:hint[0]
                                                       preferredStyle:UIAlertControllerStyleAlert];
    NSString *current = self.choices[@(f)];
    BOOL numeric = f == CFIBulkFieldMemory || f == CFIBulkFieldCores || f == CFIBulkFieldGPUMemory;
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = hint[1];
        tf.text = current.length ? current : nil;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.keyboardType = numeric ? UIKeyboardTypeNumberPad
                        : f == CFIBulkFieldOS ? UIKeyboardTypeDecimalPad : UIKeyboardTypeASCIICapable;
    }];
    __weak typeof(self) ws = self;
    __weak UIAlertController *wa = a;
    NSString *suffix = [self suffixFor:f];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *v = [wa.textFields.firstObject.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *problem = v.length ? [ws problemWithValue:v suffix:suffix] : @"is empty";
        if (problem) {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Not valid"
                message:[NSString stringWithFormat:@"\"%@\" %@.", v ?: @"", problem]
                preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [ws presentViewController:err animated:YES completion:nil];
            return;
        }
        [ws setChoice:v for:f];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Commit

- (void)commit {
    for (NSString *bid in self.bundleIDs) {
        [CFISpoofStore setAppEnabled:self.enabledState forBundle:bid];
        if (!self.enabledState) continue;   // disabling keeps each app's values for later
        for (NSInteger f = 0; f < CFIBulkFieldCount; f++) {
            NSString *v = self.choices[@(f)];
            if (!v || f == CFIBulkFieldDevice) continue;   // keep current; Device only filled the others
            [CFISpoofStore setObject:v forKey:[CFISpoofStore key:bid suffix:[self suffixFor:(CFIBulkField)f]]];
        }
    }
    if (self.onDone) self.onDone();
    [self.navigationController popViewControllerAnimated:YES];
}

@end
