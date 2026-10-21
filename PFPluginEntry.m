#import "PFPluginEntry.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PFConfig.h"
#import "PFLogger.h"
#import "PFScout.h"
#import "PFAction.h"

static NSInteger const PFSettingsEntryTag = 0x50464831;
static IMP PFOriginalViewDidAppear = NULL;
static IMP PFOriginalFMURLRouterPreProcessURL = NULL;
static NSDate *PFSettingsHomeRouteObservedAt = nil;
static NSString *PFSettingsHomeRouteObservedURL = nil;
static BOOL PFSettingsEntryRouteActive = NO;
static BOOL PFSettingsHomeRoutePendingForController(UIViewController *controller);
static void PFSettingsPageRetry(NSUInteger remainingAttempts);
static UIWindow *PFActiveKeyWindow(void);
static UIViewController *PFActiveTopViewController(void);

@class PFPluginSettingsController;

@interface PFPluginEntryManager : NSObject
@property (nonatomic, weak) UIViewController *settingsHost;
@property (nonatomic, weak) UIViewController *routeOverlayHost;
@property (nonatomic, weak) UIWindow *routeOverlayWindow;
@property (nonatomic, strong) UIButton *routeEntryButton;
+ (instancetype)shared;
- (void)settingsControllerDidAppear:(UIViewController *)controller;
- (void)installRouteEntryOverlayOnController:(UIViewController *)controller;
- (void)installRouteEntryOverlayOnWindow:(UIWindow *)window controller:(UIViewController *)controller;
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
    UIWindow *window = controller.viewIfLoaded.window ?: PFActiveKeyWindow();
    [self installRouteEntryOverlayOnWindow:window controller:controller];
}

- (void)installRouteEntryOverlayOnWindow:(UIWindow *)window controller:(UIViewController *)controller {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self installRouteEntryOverlayOnWindow:window controller:controller];
        });
        return;
    }
    if (!window || window.hidden || window.alpha <= 0.01) {
        PFLog(@"Settings route matched, but no visible key window is ready yet.");
        return;
    }

    if (controller) self.settingsHost = controller;
    self.routeOverlayHost = controller;
    self.routeOverlayWindow = window;

    if (self.routeEntryButton && self.routeEntryButton.superview == window) {
        self.routeEntryButton.hidden = NO;
        [window bringSubviewToFront:self.routeEntryButton];
        PFLog(@"Settings entry overlay re-used on UIWindow.");
        return;
    }

    [self.routeEntryButton removeFromSuperview];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = @"打开 PiggyHandFish 插件面板";
    button.accessibilityHint = @"打开猪手插件的 Runtime 侦察与诊断设置";
    button.backgroundColor = [UIColor colorWithRed:0.95 green:0.32 blue:0.10 alpha:0.98];
    [button setTitle:@"猪手" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    button.layer.cornerRadius = 19.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.28;
    button.layer.shadowRadius = 6.0;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.layer.zPosition = 1000000.0;
    button.exclusiveTouch = YES;
    [button addTarget:self action:@selector(openPluginSettings)
     forControlEvents:UIControlEventTouchUpInside];

    [window addSubview:button];
    [window bringSubviewToFront:button];
    self.routeEntryButton = button;

    UILayoutGuide *safeArea = window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],
        [button.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor constant:-8.0],
        [button.widthAnchor constraintEqualToConstant:64.0],
        [button.heightAnchor constraintEqualToConstant:38.0]
    ]];

    PFLog(@"SETTINGS_ENTRY_WINDOW_INSTALLED window=%@ controller=%@ route=%@",
          NSStringFromClass(window.class),
          controller ? NSStringFromClass(controller.class) : @"(unresolved)",
          PFSettingsHomeRouteObservedURL ?: @"(route marker unavailable)");
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
    self.routeOverlayWindow = nil;
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
        UIViewController *presenter = PFActiveTopViewController();
        if (!presenter) presenter = [self topViewControllerFrom:self.settingsHost];
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
    if (PFOriginalViewDidAppear) {
        ((void (*)(id, SEL, BOOL))PFOriginalViewDidAppear)(self, command, animated);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (PFSettingsHomeRoutePendingForController(self)) {
            PFLog(@"Matched settings web controller from recent route; adding native navigation entry.");
            [[PFPluginEntryManager shared] settingsControllerDidAppear:self];
            return;
        }
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
                NSString *lowerCandidate = candidate.lowercaseString;
                if (candidate.length &&
                    ([lowerCandidate containsString:@"fleamarket://"] ||
                     [lowerCandidate containsString:@"flutter_settings"] ||
                     [lowerCandidate containsString:@"http://"] ||
                     [lowerCandidate containsString:@"https://"] ||
                     [lowerCandidate containsString:@"personal-setting"])) {
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

static UIWindow *PFActiveKeyWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *keyWindow = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
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
        if (!keyWindow) {
            for (UIWindow *window in application.windows) {
                if (!window.hidden && window.alpha > 0.01) {
                    keyWindow = window;
                    break;
                }
            }
        }
    }
#pragma clang diagnostic pop
    return keyWindow;
}

static UIViewController *PFActiveTopViewController(void) {
    UIWindow *keyWindow = PFActiveKeyWindow();
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

static BOOL PFSettingsHomeRoutePendingForController(UIViewController *controller) {
    if (!controller) return NO;

    NSString *className = NSStringFromClass(controller.class).lowercaseString;
    if (![className containsString:@"fmwebviewcontroller"]) return NO;

    @synchronized ([PFPluginEntryManager class]) {
        if (!PFSettingsHomeRouteObservedAt) return NO;
        NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:PFSettingsHomeRouteObservedAt];
        if (age < 0 || age > 15.0) {
            PFSettingsHomeRouteObservedAt = nil;
            PFSettingsHomeRouteObservedURL = nil;
            return NO;
        }

        PFLog(@"Settings route/controller matched: %@ -> %@",
              PFSettingsHomeRouteObservedURL ?: @"(unknown route)", className);
        PFSettingsHomeRouteObservedAt = nil;
        PFSettingsHomeRouteObservedURL = nil;
        return YES;
    }
}

static void PFSettingsPageRetry(NSUInteger remainingAttempts) {
    UIWindow *window = PFActiveKeyWindow();
    UIViewController *target = PFActiveTopViewController();

    if (window) {
        PFPluginEntryManager *manager = [PFPluginEntryManager shared];
        [manager installRouteEntryOverlayOnWindow:window controller:target];

        // Retain the ZolaCN-style navigation-bar item as a secondary entry when
        // the matching native WebView controller is visible. The window button is
        // intentionally independent of this class check.
        if (target && PFSettingsHomeRoutePendingForController(target)) {
            [manager settingsControllerDidAppear:target];
        } else {
            PFLog(@"SETTINGS_ENTRY_FALLBACK window attached; activeController=%@",
                  target ? NSStringFromClass(target.class) : @"(none)");
        }
        return;
    }

    if (remainingAttempts == 0) {
        PFLog(@"SETTINGS_ENTRY_FAILED no active UIWindow after route observation.");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PFSettingsPageRetry(remainingAttempts - 1);
    });
}

static void PFHandleSettingsRoute(id urlObject) {
    NSString *route = PFRouteString(urlObject);
    NSString *lowerRoute = route.lowercaseString;
    if (!route.length) return;

    if ([lowerRoute containsString:@"idlefish-f2e"] ||
        [lowerRoute containsString:@"personal-setting"] ||
        [lowerRoute containsString:@"flutter_settings"]) {
        PFLog(@"SETTINGS_ROUTE_PROBE objectClass=%@ route=%@",
              urlObject ? NSStringFromClass([urlObject class]) : @"(nil)", route);
    }

    if ([lowerRoute containsString:@"fleamarket://flutter_settings"]) {
        PFLog(@"Confirmed Flutter Settings container route: %@", route);
        return;
    }

    // Captured runtime logs show that this exact H5 page is opened by
    // FMURLRouter and presented as FMWebViewController. Add the native bar
    // button to that controller, following the proven ZolaCN viewDidAppear pattern.
    BOOL isSettingsHome =
        [lowerRoute containsString:@"/idlefish-f2e/idle-personal-setting/home.html"] ||
        [lowerRoute containsString:@"/idlefish-f2e/idle-personal-setting/"];
    if (isSettingsHome) {
        @synchronized ([PFPluginEntryManager class]) {
            PFSettingsEntryRouteActive = YES;
            PFSettingsHomeRouteObservedAt = [NSDate date];
            PFSettingsHomeRouteObservedURL = route;
        }
        PFLog(@"Confirmed Xianyu personal-settings H5 route: %@", route);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PFSettingsPageRetry(32);
        });
    } else if ([lowerRoute containsString:@"fleamarket://personalpage"]) {
        BOOL shouldRemove = NO;
        @synchronized ([PFPluginEntryManager class]) {
            shouldRemove = PFSettingsEntryRouteActive;
            PFSettingsEntryRouteActive = NO;
            PFSettingsHomeRouteObservedAt = nil;
            PFSettingsHomeRouteObservedURL = nil;
        }
        if (shouldRemove) {
            PFLog(@"Leaving personal page; removing settings entry overlay.");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[PFPluginEntryManager shared] removeRouteEntryOverlay];
            });
        }
    }
}

static id PFFMURLRouterPreProcessURL(id self, SEL command, id url) {
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))PFOriginalFMURLRouterPreProcessURL;
    id result = original ? original(self, command, url) : url;
    PFHandleSettingsRoute(url);
    return result;
}

static BOOL PFInstallFMURLRouterHook(void) {
    Class routerClass = NSClassFromString(@"FMURLRouter");
    SEL selector = sel_registerName("preProcessURL:");
    Method method = routerClass ? class_getInstanceMethod(routerClass, selector) : NULL;

    if (!routerClass || !method) {
        PFLog(@"FMURLRouter preProcessURL hook unavailable (class=%@ method=%@).",
              routerClass ? @"found" : @"missing",
              method ? @"found" : @"missing");
        return NO;
    }

    if (method_getNumberOfArguments(method) != 3) {
        PFLog(@"FMURLRouter preProcessURL hook skipped: unexpected argument count %u.",
              method_getNumberOfArguments(method));
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    BOOL returnsObject = returnType && returnType[0] == '@';
    free(returnType);
    if (!returnsObject) {
        PFLog(@"FMURLRouter preProcessURL hook skipped: unexpected return type.");
        return NO;
    }

    char *argumentType = method_copyArgumentType(method, 2);
    BOOL argumentIsObject = argumentType && (argumentType[0] == '@' || argumentType[0] == '#');
    free(argumentType);
    if (!argumentIsObject) {
        PFLog(@"FMURLRouter preProcessURL hook skipped: URL argument is not an object.");
        return NO;
    }

    IMP currentImplementation = method_getImplementation(method);
    if (currentImplementation == (IMP)PFFMURLRouterPreProcessURL) {
        PFLog(@"FMURLRouter preProcessURL hook is already installed in this image.");
        return YES;
    }

    PFOriginalFMURLRouterPreProcessURL =
        method_setImplementation(method, (IMP)PFFMURLRouterPreProcessURL);
    PFLog(@"Installed chained route hook on Runner selector FMURLRouter preProcessURL: originalIMP=%p",
          PFOriginalFMURLRouterPreProcessURL);
    return PFOriginalFMURLRouterPreProcessURL != NULL;
}

static void PFInstallSettingsHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = UIViewController.class;
        SEL selector = @selector(viewDidAppear:);
        Method method = class_getInstanceMethod(cls, selector);

        if (!method) {
            PFLog(@"UIViewController viewDidAppear: not found");
        } else if (method_getImplementation(method) == (IMP)PFSettingsViewDidAppear) {
            PFLog(@"UIViewController viewDidAppear hook is already installed in this image.");
        } else {
            PFOriginalViewDidAppear =
                method_setImplementation(method, (IMP)PFSettingsViewDidAppear);
            PFLog(@"Chained UIViewController viewDidAppear hook installed originalIMP=%p",
                  PFOriginalViewDidAppear);
        }

        BOOL routeHookInstalled = PFInstallFMURLRouterHook();
        if (!routeHookInstalled) {
            PFLog(@"The FMURLRouter preProcessURL hook was not installed; only native title/class fallback remains.");
        }
    });
}

void PFInstallPluginEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PFInstallSettingsHook();
    });
}
