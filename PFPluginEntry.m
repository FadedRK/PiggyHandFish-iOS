#import "PFPluginEntry.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PFConfig.h"
#import "PFLogger.h"
#import "PFScout.h"
#import "PFAction.h"

static NSInteger const PFSettingsEntryTag = 0x50464831;
static NSString * const PFSettingsOriginalViewDidAppear = @"pfh_original_viewDidAppear:";

@class PFPluginSettingsController;

@interface PFPluginEntryManager : NSObject
@property (nonatomic, weak) UIViewController *settingsHost;
+ (instancetype)shared;
- (void)settingsControllerDidAppear:(UIViewController *)controller;
- (void)openPluginSettings;
@end

@interface PFPluginSettingsController : UITableViewController
@property (nonatomic, copy) NSArray<PFAction *> *actions;
@end

@implementation PFPluginEntryManager

+ (instancetype)shared {
    static PFPluginEntryManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [PFPluginEntryManager new];
    });
    return manager;
}

- (void)settingsControllerDidAppear:(UIViewController *)controller {
    if (!controller || ![NSThread isMainThread]) return;
    self.settingsHost = controller;

    NSMutableArray<UIBarButtonItem *> *items =
        [NSMutableArray arrayWithArray:controller.navigationItem.rightBarButtonItems ?: @[]];

    for (UIBarButtonItem *item in items) {
        if (item.tag == PFSettingsEntryTag) return;
    }

    UIBarButtonItem *entry =
        [[UIBarButtonItem alloc] initWithTitle:@"猪手"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(openPluginSettings)];
    entry.tag = PFSettingsEntryTag;
    [items addObject:entry];
    controller.navigationItem.rightBarButtonItems = items;

    PFLog(@"Settings entry installed on %@ (title=%@)",
          NSStringFromClass(controller.class),
          controller.navigationItem.title ?: controller.title ?: @"(untitled)");
}

- (UIViewController *)topViewControllerFrom:(UIViewController *)controller {
    if (!controller) return nil;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:[UINavigationController class]]) {
        UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
        if (visible) return [self topViewControllerFrom:visible];
    }
    if ([controller isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        if (selected) return [self topViewControllerFrom:selected];
    }
    return controller;
}

- (void)openPluginSettings {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = [self topViewControllerFrom:self.settingsHost];
        if (!presenter || presenter.presentedViewController) {
            PFLog(@"Cannot open plugin settings: presenter is unavailable or already presenting.");
            return;
        }

        PFPluginSettingsController *settings = [PFPluginSettingsController new];
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:settings];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [presenter presentViewController:navigation animated:YES completion:nil];
        PFLog(@"Plugin settings opened from the host app Settings page.");
    });
}

@end

@implementation PFPluginSettingsController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _actions = PFRegisteredActions();
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"PiggyHandFish";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(closeSettings)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return self.actions.count;
    if (section == 1) return 3;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"功能";
    if (section == 1) return @"Runtime 侦察选项";
    return @"诊断";
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"日志开关仅对当前进程生效；彻底关闭并重新启动闲鱼后会恢复默认值。";
    }
    if (section == 2) {
        return [NSString stringWithFormat:@"日志文件：%@", [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish.log"]];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const actionReuse = @"PFActionCell";
    static NSString *const toggleReuse = @"PFToggleCell";
    static NSString *const diagnosticReuse = @"PFDiagnosticCell";

    if (indexPath.section == 0) {
        UITableViewCell *cell =
            [tableView dequeueReusableCellWithIdentifier:actionReuse];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:actionReuse];
        }
        PFAction *action = self.actions[indexPath.row];
        cell.textLabel.text = action.title;
        cell.detailTextLabel.text = action.detail;
        cell.detailTextLabel.numberOfLines = 2;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell =
            [tableView dequeueReusableCellWithIdentifier:toggleReuse];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:toggleReuse];
        }

        NSArray<NSString *> *labels = @[@"类名日志", @"实例方法日志", @"类方法日志"];
        NSArray<NSNumber *> *values = @[
            @(PFGetConfig().logClasses),
            @(PFGetConfig().logMethods),
            @(PFGetConfig().logClassMethods)
        ];

        cell.textLabel.text = labels[indexPath.row];
        UISwitch *toggle = [UISwitch new];
        toggle.on = values[indexPath.row].boolValue;
        toggle.tag = indexPath.row;
        [toggle addTarget:self action:@selector(toggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:diagnosticReuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:diagnosticReuse];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (indexPath.row == 0) {
        cell.textLabel.text = @"查看运行状态";
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)";
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"(unknown)";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", bundle, version];
    } else {
        cell.textLabel.text = @"复制日志文件路径";
        cell.detailTextLabel.text = [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish.log"];
        cell.detailTextLabel.numberOfLines = 2;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        PFAction *action = self.actions[indexPath.row];
        __weak typeof(self) weakSelf = self;
        PFPerformAction(action.identifier, ^(BOOL success, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showMessage:message title:(success ? action.title : @"操作失败")];
            });
        });
        return;
    }

    if (indexPath.section == 2 && indexPath.row == 0) {
        PFConfig *config = PFGetConfig();
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)";
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"(unknown)";
        NSString *message = [NSString stringWithFormat:
            @"Bundle：%@\n版本：%@\n类名日志：%@\n实例方法日志：%@\n类方法日志：%@\n类名筛选：%@\n方法名筛选：%@\n日志文件：%@",
            bundle, version,
            config.logClasses ? @"开" : @"关",
            config.logMethods ? @"开" : @"关",
            config.logClassMethods ? @"开" : @"关",
            config.classRegex, config.methodRegex,
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish.log"]];
        [self showMessage:message title:@"运行状态"];
    } else if (indexPath.section == 2 && indexPath.row == 1) {
        UIPasteboard.generalPasteboard.string =
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish.log"];
        [self showMessage:@"日志文件路径已复制到剪贴板。" title:@"PiggyHandFish"];
    }
}

- (void)toggleChanged:(UISwitch *)sender {
    PFConfig *config = PFGetConfig();
    switch (sender.tag) {
        case 0: config.logClasses = sender.isOn; break;
        case 1: config.logMethods = sender.isOn; break;
        case 2: config.logClassMethods = sender.isOn; break;
        default: return;
    }
    PFLog(@"Plugin setting changed: toggle=%ld value=%@",
          (long)sender.tag, sender.isOn ? @"ON" : @"OFF");
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    if (!self.view.window) return;
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)closeSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static BOOL PFLooksLikeSettings(UIViewController *controller) {
    if (!controller) return NO;

    NSString *className = NSStringFromClass(controller.class).lowercaseString;
    if ([className hasPrefix:@"pfplugin"]) return NO;

    NSString *title = (controller.navigationItem.title ?: controller.title ?: @"").lowercaseString;
    if ([className containsString:@"setting"] ||
        [className containsString:@"preferences"]) {
        return YES;
    }

    NSArray<NSString *> *knownTitles = @[@"设置", @"settings", @"setting", @"cài đặt"];
    for (NSString *knownTitle in knownTitles) {
        if ([title isEqualToString:knownTitle]) return YES;
    }
    return NO;
}

static void PFConfigureSettingsEntry(UIViewController *controller) {
    if (!PFLooksLikeSettings(controller)) return;

    for (UIBarButtonItem *item in controller.navigationItem.rightBarButtonItems ?: @[]) {
        if (item.tag == PFSettingsEntryTag) return;
    }

    [[PFPluginEntryManager shared] settingsControllerDidAppear:controller];
}

static void PFSettingsViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    SEL originalSelector = sel_registerName("pfh_original_viewDidAppear:");
    void (*original)(id, SEL, BOOL) =
        (void (*)(id, SEL, BOOL))[self methodForSelector:originalSelector];
    if (original) original(self, originalSelector, animated);

    dispatch_async(dispatch_get_main_queue(), ^{
        PFConfigureSettingsEntry(self);
    });
}

static void PFInstallSettingsHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = UIViewController.class;
        SEL originalSelector = @selector(viewDidAppear:);
        SEL aliasSelector = sel_registerName("pfh_original_viewDidAppear:");
        Method method = class_getInstanceMethod(cls, originalSelector);
        if (!method) {
            NSLog(@"[PiggyHandFish] UIViewController viewDidAppear: not found");
            return;
        }
        if (class_getInstanceMethod(cls, aliasSelector)) return;

        class_addMethod(cls, aliasSelector,
                        method_getImplementation(method),
                        method_getTypeEncoding(method));
        method_setImplementation(method, (IMP)PFSettingsViewDidAppear);
        PFLog(@"Settings page hook installed.");
    });
}

void PFInstallPluginEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PFInstallSettingsHook();
    });
}
