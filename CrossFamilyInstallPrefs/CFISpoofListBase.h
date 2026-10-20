#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// Real PSSpecifier methods that Theos' headers don't declare.
@interface PSSpecifier (CFIPrivate)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
- (void)setKeyboardType:(UIKeyboardType)type
               autoCaps:(UITextAutocapitalizationType)autoCaps
         autoCorrection:(UITextAutocorrectionType)autoCorrection;
@end

// Base for the Per-App Spoofing pages. Values go to the draft in CFISpoofStore
// and go live with Apply on the main page.
@interface CFISpoofListBase : PSListController

// Runs `proceed` right away if every enabled app's values are valid, otherwise
// once the user agrees to have the invalid ones ignored.
+ (void)checkFrom:(UIViewController *)vc then:(void (^)(void))proceed;
+ (void)resetFrom:(UIViewController *)vc done:(void (^)(void))done;

- (PSSpecifier *)groupNamed:(NSString *)name footer:(NSString *)footer;
- (PSSpecifier *)switchNamed:(NSString *)name key:(NSString *)key;
- (PSSpecifier *)buttonNamed:(NSString *)name action:(SEL)action;
- (PSSpecifier *)choiceNamed:(NSString *)name key:(NSString *)key
                      values:(NSArray<NSString *> *)values titles:(NSArray<NSString *> *)titles;
- (PSSpecifier *)textNamed:(NSString *)name key:(NSString *)key placeholder:(NSString *)placeholder;
@end
