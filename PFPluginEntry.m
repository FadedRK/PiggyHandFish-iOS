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
@property (nonatomic, weak) UIViewController *routeOverlayHost;
@property (nonatomic, strong) UIButton *routeEntryButton;
+ (instancetype)shared;
- (void)settingsControllerDidAppear:(UIViewController *)controller;
- (void)installRouteEntryOverlayOnController:(UIViewController *)controller;
- (void)removeRouteEntryOverlay;
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

- (void)installRouteEntryOverlayOnController:(UIViewController *)controller {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self installRouteEntryOverlayOnController:controller];
        });
        return;
    }
    if (!controller || !controller.isViewLoaded || !controller.view.window) {
        PFLog(@"Settings route detected, but the target view is not in a window yet.");
        return;
    }

    self.settingsHost = controller;
    if (self.routeEntryButton && self.routeOverlayHost == controller &&
        self.routeEntryButton.superview == controller.view) {
        self.routeEntryButton.hidden = NO;
        return;
    }

    [self.routeEntryButton removeFromSuperview];
    self.routeOverlayHost = controller;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = @"打开 PiggyHandFish 插件面板";
    button.accessibilityHint = @"打开猪手插件的 Runtime 侦察与诊断设置";
    button.backgroundColor = [UIColor colorWithRed:0.95 green:0.43 blue:0.16 alpha:0.97];
    [button setTitle:@"猪手" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 17.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.22;
    button.layer.shadowRadius = 5.0;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.layer.zPosition = 9999.0;
    button.exclusiveTouch = YES;
    [button addTarget:self action:@selector(openPluginSettings)
     forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:button];
    self.routeEntryButton = button;
    UILayoutGuide *safeArea = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],
        [button.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8.0],
        [button.widthAnchor constraintEqualToConstant:56.0],
        [button.heightAnchor constraintEqualToConstant:34.0]
    ]];

    PFLog(@"Settings route overlay installed on %@ (view=%@).",
          NSStringFromClass(controller.class),
          NSStringFromClass(controller.view.class));
}

- (void)removeRouteEntryOverlay {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self removeRouteEntryOverlay];
        });
        return;
    }
    if (self.routeEntryButton) {
        [self.routeEntryButton removeFromSuperview];
        PFLog(@"Settings route overlay removed after a different app route.");
    }
    self.routeEntryButton = nil;
    self.routeOverlayHost = nil;
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

static NSString *PFRouteStringDepth(id route, NSUInteger depth) {
    if (!route || route == [NSNull null] || depth > 3) return @"";
    if ([route isKindOfClass:[NSString class]]) return route;
    if ([route isKindOfClass:[NSURL class]]) return [(NSURL *)route absoluteString];

    NSArray<NSString *> *keys = @[@"urlString", @"urlPath", @"absoluteString", @"url", @"path"];
    for (NSString *key in keys) {
        @try {
            id value = [route valueForKey:key];
            if (value && value != route) {
                NSString *candidate = PFRouteStringDepth(value, depth + 1);
                if (candidate.length &&
                    ([candidate.lowercaseString containsString:@"fleamarket://"] ||
                     [candidate.lowercaseString containsString:@"flutter_settings"])) {
                    return candidate;
                }
            }
        } @catch (__unused NSException *exception) {}
    }

    if ([route isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in keys) {
            id value = ((NSDictionary *)route)[key];
            NSString *candidate = PFRouteStringDepth(value, depth + 1);
            if (candidate.length) return candidate;
        }
    }

    return [route description] ?: @"";
}

static NSString *PFRouteString(id route) {
    return PFRouteStringDepth(route, 0);
}

static UIViewController *PFActiveTopViewController(void) {
    UIWindow *keyWindow = nil;
    UIApplication *application = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow && !window.hidden && window.alpha > 0.01) {
                    keyWindow = window;
                    break;
                }
            }
            if (keyWindow) break;
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!keyWindow) {
        for (UIWindow *window in application.windows) {
            if (window.isKeyWindow && !window.hidden && window.alpha > 0.01) {
                keyWindow = window;
                break;
            }
        }
    }
#pragma clang diagnostic pop

    UIViewController *controller = keyWindow.rootViewController;
    while (controller) {
        if (controller.presentedViewController) {
            controller = controller.presentedViewController;
            continue;
        }
        if ([controller isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
            if (visible) {
                controller = visible;
                continue;
            }
        }
        if ([controller isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
            if (selected) {
                controller = selected;
                continue;
            }
        }
        break;
    }
    return controller;
}

static void PFSettingsRouteOverlayAttempt(NSUInteger remainingAttempts) {
    UIViewController *target = PFActiveTopViewController();
    if (target && target.isViewLoaded && target.view.window) {
        [[PFPluginEntryManager shared] installRouteEntryOverlayOnController:target];
        return;
    }

    if (remainingAttempts == 0) {
        PFLog(@"Could not attach Settings route overlay: no visible view controller was found.");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PFSettingsRouteOverlayAttempt(remainingAttempts - 1);
    });
}

static void PFHandleSettingsRoute(id urlObject) {
    NSString *route = PFRouteString(urlObject);
    NSString *lowerRoute = route.lowercaseString;
    BOOL isSettingsRoute =
        [lowerRoute containsString:@"fleamarket://flutter_settings"] ||
        [lowerRoute containsString:@"flutter_settings"];

    if (isSettingsRoute) {
        PFLog(@"Detected Xianyu Flutter Settings route from FMURLRouter: %@", route);
        // Flutter may change its page without presenting a new native UIViewController.
        // A native overlay button works even when the page itself has no UINavigationBar.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PFSettingsRouteOverlayAttempt(16);
        });
    } else if (route.length &&
               ([lowerRoute containsString:@"fleamarket://"] ||
                [lowerRoute containsString:@"http://"] ||
                [lowerRoute containsString:@"https://"])) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[PFPluginEntryManager shared] removeRouteEntryOverlay];
        });
    } else {
        PFLog(@"FMURLRouter URL argument could not be resolved to a route (class=%@).",
              urlObject ? NSStringFromClass([urlObject class]) : @"(nil)");
    }
}

static NSString * const PFFMURLRouterOpenAliasName =
    @"pfh_original_openURL:withQuery:withParams:";

static BOOL PFFMURLRouterOpenURL(id self, SEL command, id url, id query, id params) {
    SEL alias = NSSelectorFromString(PFFMURLRouterOpenAliasName);
    BOOL (*original)(id, SEL, id, id, id) =
        (BOOL (*)(id, SEL, id, id, id))[self methodForSelector:alias];
    BOOL result = original ? original(self, alias, url, query, params) : NO;
    PFHandleSettingsRoute(url);
    return result;
}

static BOOL PFInstallFMURLRouterHook(void) {
    Class routerClass = NSClassFromString(@"FMURLRouter");
    SEL selector = sel_registerName("openURL:withQuery:withParams:");
    SEL alias = NSSelectorFromString(PFFMURLRouterOpenAliasName);
    Method method = routerClass ? class_getInstanceMethod(routerClass, selector) : NULL;

    if (!routerClass || !method) {
        PFLog(@"FMURLRouter route hook unavailable (class=%@ method=%@).",
              routerClass ? @"found" : @"missing",
              method ? @"found" : @"missing");
        return NO;
    }

    if (method_getNumberOfArguments(method) != 5) {
        PFLog(@"FMURLRouter openURL hook skipped: unexpected argument count %u.",
              method_getNumberOfArguments(method));
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    BOOL returnsBoolean = returnType &&
        (returnType[0] == 'B' || returnType[0] == 'c' || returnType[0] == 'C');
    free(returnType);
    if (!returnsBoolean) {
        PFLog(@"FMURLRouter openURL hook skipped: unexpected return type.");
        return NO;
    }

    for (unsigned int index = 2; index <= 4; index++) {
        char *type = method_copyArgumentType(method, index);
        BOOL isObject = type && (type[0] == '@' || type[0] == '#');
        free(type);
        if (!isObject) {
            PFLog(@"FMURLRouter openURL hook skipped: argument %u is not an object.", index);
            return NO;
        }
    }

    if (!class_addMethod(routerClass, alias, method_getImplementation(method),
                         method_getTypeEncoding(method))) {
        PFLog(@"FMURLRouter openURL hook skipped: alias already exists.");
        return NO;
    }

    method_setImplementation(method, (IMP)PFFMURLRouterOpenURL);
    PFLog(@"Installed route hook on confirmed Runner class FMURLRouter openURL:withQuery:withParams:.");
    return YES;
}

static void PFInstallSettingsHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = UIViewController.class;
        SEL selector = @selector(viewDidAppear:);
        SEL alias = NSSelectorFromString(PFSettingsOriginalViewDidAppear);
        Method method = class_getInstanceMethod(cls, selector);

        if (method && !class_getInstanceMethod(cls, alias)) {
            class_addMethod(cls, alias,
                            method_getImplementation(method),
                            method_getTypeEncoding(method));
            method_setImplementation(method, (IMP)PFSettingsViewDidAppear);
            PFLog(@"Generic native Settings title/class fallback hook installed.");
        } else if (!method) {
            PFLog(@"UIViewController viewDidAppear: not found");
        }

        BOOL routeHookInstalled = PFInstallFMURLRouterHook();
        if (!routeHookInstalled) {
            PFLog(@"The exact FMURLRouter hook was not installed; only native title/class fallback remains.");
        }
    });
}

void PFInstallPluginEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PFInstallSettingsHook();
    });
}
