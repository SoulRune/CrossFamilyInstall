#import <UIKit/UIKit.h>

// Sets the same values on several apps (and turns them on or off). Every field
// starts at "Keep current", so only the fields you pick are overwritten.
@interface CFIBulkSpoofController : UITableViewController
- (instancetype)initWithBundleIDs:(NSArray<NSString *> *)bundleIDs;
@property (nonatomic, copy) void (^onDone)(void);
@end
