#import "CFISpoofListBase.h"
#import "CFISpoofStore.h"
#import <UIKit/UIKit.h>

@implementation CFISpoofListBase

#pragma mark - Draft persistence

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    id value = [CFISpoofStore objectForKey:[specifier propertyForKey:@"key"]];
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    // Draft only - the main page's Apply is the single commit point.
    [CFISpoofStore setObject:value forKey:[specifier propertyForKey:@"key"]];
}

#pragma mark - Apply / Reset

// Enabled apps whose draft has a value the tweak would ignore.
+ (NSArray<NSString *> *)invalidEntries {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[CFISpoofStore draftPath]];
    NSMutableArray *bad = [NSMutableArray array];
    for (NSString *key in d) {
        if (![key hasPrefix:@"enabled-"] || ![d[key] boolValue]) continue;
        NSString *bid = [key substringFromIndex:@"enabled-".length];
        for (NSString *suffix in [CFISpoofStore valueSuffixes]) {
            NSString *value = d[[CFISpoofStore key:bid suffix:suffix]];
            if ([CFISpoofStore problemWithValue:value suffix:suffix bundle:bid]) {
                [bad addObject:[NSString stringWithFormat:@"%@: %@ \"%@\"", bid, suffix, value]];
            }
        }
    }
    return bad;
}

+ (void)checkFrom:(UIViewController *)vc then:(void (^)(void))proceed {
    NSArray *bad = [self invalidEntries];
    if (bad.count == 0) { proceed(); return; }
    NSString *msg = [NSString stringWithFormat:@"Will be ignored:\n\n%@", [bad componentsJoinedByString:@"\n"]];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Some values are invalid"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Apply anyway" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        proceed();
    }]];
    [vc presentViewController:a animated:YES completion:nil];
}

+ (void)resetFrom:(UIViewController *)vc done:(void (^)(void))done {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset Per-App Spoofing?"
                                                              message:@"Clears all apps' values and applies immediately."
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        [CFISpoofStore resetAll];
        if (done) done();
    }]];
    [vc presentViewController:a animated:YES completion:nil];
}

#pragma mark - Specifier builders

- (PSSpecifier *)groupNamed:(NSString *)name footer:(NSString *)footer {
    PSSpecifier *g = [PSSpecifier groupSpecifierWithName:name];
    if (footer.length) [g setProperty:footer forKey:@"footerText"];
    return g;
}

- (PSSpecifier *)valueSpecifierNamed:(NSString *)name key:(NSString *)key cell:(PSCellType)cell detail:(Class)detail {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                   target:self
                                                      set:@selector(setPreferenceValue:specifier:)
                                                      get:@selector(readPreferenceValue:)
                                                   detail:detail
                                                     cell:cell
                                                     edit:Nil];
    [s setProperty:key forKey:@"key"];
    return s;
}

- (PSSpecifier *)switchNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *s = [self valueSpecifierNamed:name key:key cell:PSSwitchCell detail:Nil];
    [s setProperty:@NO forKey:@"default"];
    return s;
}

- (PSSpecifier *)choiceNamed:(NSString *)name key:(NSString *)key
                      values:(NSArray<NSString *> *)values titles:(NSArray<NSString *> *)titles {
    PSSpecifier *s = [self valueSpecifierNamed:name key:key cell:PSLinkListCell
                                        detail:NSClassFromString(@"PSListItemsController")];
    [s setValues:values titles:titles];
    [s setProperty:@"" forKey:@"default"];
    return s;
}

- (PSSpecifier *)textNamed:(NSString *)name key:(NSString *)key placeholder:(NSString *)placeholder {
    PSSpecifier *s = [self valueSpecifierNamed:name key:key cell:PSEditTextCell detail:Nil];
    [s setProperty:@"" forKey:@"default"];
    if (placeholder) [s setProperty:placeholder forKey:@"placeholder"];
    [s setKeyboardType:UIKeyboardTypeASCIICapable
              autoCaps:UITextAutocapitalizationTypeNone
        autoCorrection:UITextAutocorrectionTypeNo];
    return s;
}

- (PSSpecifier *)buttonNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name target:self set:NULL get:NULL
                                                   detail:Nil cell:PSButtonCell edit:Nil];
    s->action = action;
    [s setProperty:@YES forKey:@"enabled"];
    return s;
}

@end
