#import "CFIAppsTableController.h"
#import "CFIAppSpoofController.h"
#import "CFIBulkSpoofController.h"
#import "CFISpoofStore.h"
#import <Preferences/PSSpecifier.h>

@interface CFIAppsTableController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *enabledApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *disabledApps;
@property (nonatomic, copy)   NSString *filter;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *icons;
@property (nonatomic, strong) NSMutableSet<NSString *> *selected;
@end

@implementation CFIAppsTableController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _icons = [NSCache new];
        _selected = [NSMutableSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Apps";
    self.allApps = [CFISpoofStore userApps];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"Search name or bundle id";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    self.tableView.rowHeight = 50.0;
    [self updateBars];
    [self recompute];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self recompute];   // reflect changes made on a detail page
    self.navigationController.toolbarHidden = !self.tableView.isEditing;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.toolbarHidden = YES;
}

#pragma mark - Data

- (void)recompute {
    NSArray *apps = self.allApps;
    NSString *f = self.filter.lowercaseString;
    if (f.length) {
        apps = [apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *b) {
            return [[app[@"name"] lowercaseString] containsString:f] || [[app[@"id"] lowercaseString] containsString:f];
        }]];
    }
    NSMutableArray *en = [NSMutableArray array], *dis = [NSMutableArray array];
    for (NSDictionary *app in apps) [([CFISpoofStore appEnabled:app[@"id"]] ? en : dis) addObject:app];
    self.enabledApps = en;
    self.disabledApps = dis;
    [self.tableView reloadData];
    [self restoreSelection];
}

// reloadData drops row selection; re-select whatever is still in the set
// (e.g. after the search filter changes while selecting).
- (void)restoreSelection {
    if (!self.tableView.isEditing) return;
    for (NSInteger sec = 0; sec < 2; sec++) {
        NSArray *apps = sec == 0 ? self.enabledApps : self.disabledApps;
        for (NSUInteger r = 0; r < apps.count; r++) {
            if ([self.selected containsObject:apps[r][@"id"]]) {
                [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)r inSection:sec]
                                            animated:NO scrollPosition:UITableViewScrollPositionNone];
            }
        }
    }
}

- (NSDictionary *)appAt:(NSIndexPath *)ip {
    return ip.section == 0 ? self.enabledApps[ip.row] : self.disabledApps[ip.row];
}

// App icon scaled to a fixed square (cached - the list can be long).
- (UIImage *)iconForBundle:(NSString *)bid side:(CGFloat)side {
    UIImage *cached = [self.icons objectForKey:bid];
    if (cached) return cached;
    UIImage *img = [CFISpoofStore iconForBundle:bid];
    if (!img) return nil;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *scaled = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, side, side)];
    }];
    [self.icons setObject:scaled forKey:bid];
    return scaled;
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    self.filter = searchController.searchBar.text;
    [self recompute];
}

#pragma mark - Bars / multi-select

- (void)updateBars {
    BOOL editing = self.tableView.isEditing;
    if (editing) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(exitSelect)];
        NSString *setTitle = self.selected.count
            ? [NSString stringWithFormat:@"Set Values (%lu)", (unsigned long)self.selected.count] : @"Set Values";
        UIBarButtonItem *setBtn = [[UIBarButtonItem alloc] initWithTitle:setTitle style:UIBarButtonItemStylePlain
                                                                  target:self action:@selector(setValuesForSelection)];
        setBtn.enabled = self.selected.count > 0;
        UIBarButtonItem *all = [[UIBarButtonItem alloc] initWithTitle:@"Select All" style:UIBarButtonItemStylePlain
                                                               target:self action:@selector(selectAll)];
        UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        self.toolbarItems = @[setBtn, flex, all];
    } else {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"Select" style:UIBarButtonItemStylePlain target:self action:@selector(enterSelect)];
        self.toolbarItems = nil;
    }
    // The toolbar is only for multi-select; Apply is on the main page.
    self.navigationController.toolbarHidden = !editing;
}

- (void)enterSelect {
    [self.selected removeAllObjects];
    [self setEditing:YES animated:YES];
    [self.tableView reloadData];
    [self updateBars];
}

- (void)exitSelect {
    [self setEditing:NO animated:YES];
    [self.selected removeAllObjects];
    [self.tableView reloadData];
    [self updateBars];
}

// Selects every app currently shown (respects the search filter).
- (void)selectAll {
    for (NSDictionary *app in self.enabledApps)  [self.selected addObject:app[@"id"]];
    for (NSDictionary *app in self.disabledApps) [self.selected addObject:app[@"id"]];
    [self restoreSelection];
    [self updateBars];
}

- (void)setValuesForSelection {
    if (self.selected.count == 0) return;
    CFIBulkSpoofController *vc = [[CFIBulkSpoofController alloc] initWithBundleIDs:self.selected.allObjects];
    __weak typeof(self) weakSelf = self;
    vc.onDone = ^{ [weakSelf exitSelect]; [weakSelf recompute]; };
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.enabledApps.count : self.disabledApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? [NSString stringWithFormat:@"Enabled (%lu)", (unsigned long)self.enabledApps.count]
                        : [NSString stringWithFormat:@"Disabled (%lu)", (unsigned long)self.disabledApps.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    NSDictionary *app = [self appAt:indexPath];
    NSString *bid = app[@"id"];
    cell.textLabel.text = app[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:15.0];

    // Enabled apps show what they're spoofed to, so the list doubles as an overview.
    NSString *summary = indexPath.section == 0 ? [CFISpoofStore summaryForBundle:bid] : nil;
    cell.detailTextLabel.text = summary ? [NSString stringWithFormat:@"%@ - %@", summary, bid] : bid;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
    cell.detailTextLabel.textColor = summary ? [UIColor systemBlueColor] : [UIColor secondaryLabelColor];

    cell.imageView.image = [self iconForBundle:bid side:30.0];
    cell.imageView.layer.cornerRadius = 6.0;
    cell.imageView.clipsToBounds = YES;
    cell.accessoryType = self.tableView.isEditing ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *app = [self appAt:indexPath];
    if (self.tableView.isEditing) {
        [self.selected addObject:app[@"id"]];
        [self updateBars];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:app[@"name"] target:nil set:NULL get:NULL
                                                       detail:Nil cell:PSLinkCell edit:Nil];
    [spec setProperty:app[@"id"] forKey:@"bid"];
    CFIAppSpoofController *vc = [[CFIAppSpoofController alloc] init];
    [vc setSpecifier:spec];
    vc.title = app[@"name"];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.tableView.isEditing) {
        [self.selected removeObject:[self appAt:indexPath][@"id"]];
        [self updateBars];
    }
}

// Trailing (swipe-left) quick enable/disable toggle.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *bid = [self appAt:indexPath][@"id"];
    BOOL enabled = [CFISpoofStore appEnabled:bid];
    UIContextualAction *act = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                      title:(enabled ? @"Disable" : @"Enable")
                                                                    handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [CFISpoofStore setAppEnabled:!enabled forBundle:bid];
        done(YES);
        [self recompute];
    }];
    act.backgroundColor = enabled ? [UIColor systemRedColor] : [UIColor systemGreenColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[act]];
}

@end
