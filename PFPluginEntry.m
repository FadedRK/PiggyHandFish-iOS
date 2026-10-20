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

static NSString *PFRouteString(id route) {
    if (!route || route == [NSNull null]) return @"";
    if ([route isKindOfClass:[NSString class]]) return route;
    if ([route isKindOfClass:[NSURL class]]) return [(NSURL *)route absoluteString];
    @try {
        id absoluteString = [route valueForKey:@"absoluteString"];
        if ([absoluteString isKindOfClass:[NSString class]]) return absoluteString;
    } @catch (__unused NSException *exception) {}
    return [route description] ?: @"";
}

static BOOL PFClassDefinesSelector(Class cls, SEL selector) {
    if (!cls || !selector) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static char PFNavigatorPushReturnKind(Method method) {
    if (!method || method_getNumberOfArguments(method) != 6) return '\0';

    char *returnType = method_copyReturnType(method);
    char kind = returnType ? returnType[0] : '\0';
    free(returnType);
    if (kind != 'v' && kind != '@') return '\0';

    for (unsigned int index = 2; index <= 4; index++) {
        char *type = method_copyArgumentType(method, index);
        BOOL isObject = type && (type[0] == '@' || type[0] == '#');
        free(type);
        if (!isObject) return '\0';
    }

    char *lastType = method_copyArgumentType(method, 5);
    BOOL isBoolean = lastType && (lastType[0] == 'B' || lastType[0] == 'c' || lastType[0] == 'C');
    free(lastType);
    return isBoolean ? kind : '\0';
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
                if (window.isKeyWindow && !window.hidden) {
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
            if (window.isKeyWindow && !window.hidden) {
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

static NSString * const PFNavigatorPushAliasName = @"pfh_original_pushController:withUrl:withNavigator:popBefore:";

static void PFHandleSettingsRoute(id controllerObject, id urlObject) {
    NSString *route = PFRouteString(urlObject);
    NSString *lowerRoute = route.lowercaseString;
    // These route names were found in the supplied Runner Mach-O.
    BOOL isSettingsRoute =
        [lowerRoute containsString:@"fleamarket://flutter_settings"] ||
        [lowerRoute containsString:@"flutter_settings"];

    if (!isSettingsRoute) return;

    PFLog(@"Detected Xianyu Settings route from Runner: %@", route);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *target =
            [controllerObject isKindOfClass:[UIViewController class]]
                ? (UIViewController *)controllerObject : nil;

        if (!target.navigationController ||
            target.navigationController.topViewController != target) {
            UIViewController *visible = PFActiveTopViewController();
            if (visible) target = visible;
        }

        if (target) {
            [[PFPluginEntryManager shared] settingsControllerDidAppear:target];
            PFLog(@"Settings entry attached to route controller: %@",
                  NSStringFromClass(target.class));
        } else {
            PFLog(@"Settings route detected, but the visible UIViewController was unavailable.");
        }
    });
}

static void PFNavigatorPushControllerVoid(id self,
                                          SEL command,
                                          id controller,
                                          id url,
                                          id navigator,
                                          BOOL popBefore) {
    SEL alias = NSSelectorFromString(PFNavigatorPushAliasName);
    void (*original)(id, SEL, id, id, id, BOOL) =
        (void (*)(id, SEL, id, id, id, BOOL))[self methodForSelector:alias];
    if (original) original(self, alias, controller, url, navigator, popBefore);
    PFHandleSettingsRoute(controller, url);
}

static id PFNavigatorPushControllerObject(id self,
                                          SEL command,
                                          id controller,
                                          id url,
                                          id navigator,
                                          BOOL popBefore) {
    SEL alias = NSSelectorFromString(PFNavigatorPushAliasName);
    id (*original)(id, SEL, id, id, id, BOOL) =
        (id (*)(id, SEL, id, id, id, BOOL))[self methodForSelector:alias];
    id result = original ? original(self, alias, controller, url, navigator, popBefore) : nil;
    PFHandleSettingsRoute(controller, url);
    return result;
}

static void PFInstallNavigatorRouteHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL selector = sel_registerName("pushController:withUrl:withNavigator:popBefore:");
        SEL alias = NSSelectorFromString(PFNavigatorPushAliasName);

        int classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) {
            PFLog(@"Navigator hook skipped: Objective-C runtime returned no classes.");
            return;
        }

        Class *classes = calloc((size_t)classCount, sizeof(Class));
        if (!classes) {
            PFLog(@"Navigator hook skipped: could not allocate class list.");
            return;
        }

        int actualCount = objc_getClassList(classes, classCount);
        NSUInteger installed = 0;
        for (int index = 0; index < actualCount; index++) {
            Class cls = classes[index];
            if (!PFClassDefinesSelector(cls, selector)) continue;

            Method method = class_getInstanceMethod(cls, selector);
            char returnKind = PFNavigatorPushReturnKind(method);
            if (!returnKind) {
                PFLog(@"Navigator route hook skipped for %@: unsupported encoding %@",
                      NSStringFromClass(cls),
                      method ? [NSString stringWithUTF8String:method_getTypeEncoding(method)] : @"(missing)");
                continue;
            }

            IMP previous = method_getImplementation(method);
            const char *types = method_getTypeEncoding(method);
            if (!class_addMethod(cls, alias, previous, types)) {
                PFLog(@"Navigator route hook skipped for %@: original-method alias already exists.",
                      NSStringFromClass(cls));
                continue;
            }

            IMP replacement = returnKind == 'v'
                ? (IMP)PFNavigatorPushControllerVoid
                : (IMP)PFNavigatorPushControllerObject;
            method_setImplementation(method, replacement);
            installed++;
            PFLog(@"Installed route-aware Settings hook on %@ (%@ return).",
                  NSStringFromClass(cls),
                  returnKind == 'v' ? @"void" : @"object");
        }

        free(classes);
        if (installed == 0) {
            PFLog(@"No compatible native route-push method found; Settings title/class fallback remains enabled.");
        } else {
            PFLog(@"Route-aware Settings hooks installed: %lu", (unsigned long)installed);
        }
    });
}

static void PFInstallSettingsHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = UIViewController.class;
        SEL selector = @selector(viewDidAppear:);
        SEL alias = sel_registerName("pfh_original_viewDidAppear:");
        Method method = class_getInstanceMethod(cls, selector);

        if (method && !class_getInstanceMethod(cls, alias)) {
            class_addMethod(cls, alias,
                            method_getImplementation(method),
                            method_getTypeEncoding(method));
            method_setImplementation(method, (IMP)PFSettingsViewDidAppear);
            PFLog(@"Generic Settings title/class fallback hook installed.");
        } else if (!method) {
            PFLog(@"UIViewController viewDidAppear: not found");
        }

        PFInstallNavigatorRouteHook();
    });
}

void PFInstallPluginEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PFInstallSettingsHook();
    });
}
