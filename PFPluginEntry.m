#import "PFPluginEntry.h"
#import <UIKit/UIKit.h>
#import "PFConfig.h"
#import "PFLogger.h"
#import "PFScout.h"
#import "PFAction.h"

static NSString *PFPluginLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish.log"];
}

@interface PFPluginEntryManager : NSObject
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIButton *entryButton;
@property (nonatomic, strong) NSLayoutConstraint *rightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;
@property (nonatomic, assign) NSUInteger installAttempts;
@property (nonatomic, assign) BOOL observerInstalled;
+ (instancetype)shared;
- (void)start;
- (void)installEntryWhenReady;
- (void)presentMenu;
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

- (void)start {
    NSAssert([NSThread isMainThread], @"Plugin entry must be installed on the main thread.");
    if (!self.observerInstalled) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        self.observerInstalled = YES;
    }
    [self installEntryWhenReady];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.installAttempts = 0;
        [self installEntryWhenReady];
    });
}

- (UIWindow *)activeWindow {
    UIApplication *application = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow && !window.hidden) return window;
            }
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden && window.alpha > 0.01 && window.rootViewController) return window;
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {
        if (window.isKeyWindow && !window.hidden) return window;
    }
    for (UIWindow *window in application.windows) {
        if (!window.hidden && window.alpha > 0.01 && window.rootViewController) return window;
    }
#pragma clang diagnostic pop
    return nil;
}

- (void)installEntryWhenReady {
    NSAssert([NSThread isMainThread], @"Plugin entry must be installed on the main thread.");
    UIWindow *window = [self activeWindow];

    if (!window) {
        if (self.installAttempts < 30) {
            self.installAttempts++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self installEntryWhenReady];
            });
        } else {
            PFLog(@"Plugin entry not installed: no active app window was found.");
        }
        return;
    }

    if (self.entryButton && self.entryButton.superview == window) return;
    [self.entryButton removeFromSuperview];
    self.hostWindow = window;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = @"打开 PiggyHandFish 插件面板";
    button.accessibilityHint = @"运行时侦察、切换日志选项和导出诊断日志";
    button.backgroundColor = [UIColor colorWithRed:0.95 green:0.43 blue:0.16 alpha:0.96];
    [button setTitle:@"猪手" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 24.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.8].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.2;
    button.layer.shadowRadius = 6.0;
    button.layer.shadowOffset = CGSizeMake(0, 3);
    button.exclusiveTouch = YES;
    [button addTarget:self action:@selector(entryButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    [window addSubview:button];
    self.entryButton = button;
    self.rightConstraint = [button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-14.0];
    self.bottomConstraint = [button.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-105.0];
    [NSLayoutConstraint activateConstraints:@[
        self.rightConstraint,
        self.bottomConstraint,
        [button.widthAnchor constraintEqualToConstant:58.0],
        [button.heightAnchor constraintEqualToConstant:48.0]
    ]];

    PFLog(@"Plugin entry installed in host window.");
}

- (void)entryButtonTapped:(UIButton *)sender {
    [self presentMenu];
}

- (UIViewController *)topViewControllerFrom:(UIViewController *)controller {
    if (!controller) return nil;
    if (controller.presentedViewController) {
        return [self topViewControllerFrom:controller.presentedViewController];
    }
    if ([controller isKindOfClass:[UINavigationController class]]) {
        return [self topViewControllerFrom:((UINavigationController *)controller).visibleViewController];
    }
    if ([controller isKindOfClass:[UITabBarController class]]) {
        return [self topViewControllerFrom:((UITabBarController *)controller).selectedViewController];
    }
    return controller;
}

- (void)addToggleActionToSheet:(UIAlertController *)sheet
                         title:(NSString *)title
                         value:(BOOL)value
                           set:(void (^)(BOOL newValue))setter {
    NSString *label = [NSString stringWithFormat:@"%@：%@", title, value ? @"开" : @"关"];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        BOOL newValue = !value;
        setter(newValue);
        PFLog(@"Plugin setting changed for current session: %@ = %@", title, newValue ? @"ON" : @"OFF");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf presentMenu];
        });
    }]];
}

- (NSString *)statusMessage {
    PFConfig *config = PFGetConfig();
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)";
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"(unknown)";
    return [NSString stringWithFormat:
            @"Bundle：%@\n版本：%@\n类名日志：%@\n实例方法日志：%@\n类方法日志：%@\n类名筛选：%@\n方法名筛选：%@\n日志文件：%@\n\n开关只影响当前进程，会话结束后恢复编译时默认值。",
            bundle, version,
            config.logClasses ? @"开" : @"关",
            config.logMethods ? @"开" : @"关",
            config.logClassMethods ? @"开" : @"关",
            config.classRegex, config.methodRegex, PFPluginLogPath()];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *top = [weakSelf topViewControllerFrom:weakSelf.hostWindow.rootViewController];
        if (!top || top.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

- (void)copyLogToPasteboard {
    NSError *error = nil;
    NSString *path = PFPluginLogPath();
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!content) {
        [self showMessage:error.localizedDescription ?: @"尚无日志文件，请先运行一次侦察。" title:@"复制日志失败"];
        return;
    }

    const NSUInteger maxCharacters = 30000;
    if (content.length > maxCharacters) {
        content = [content substringFromIndex:content.length - maxCharacters];
        content = [@"(仅复制最近 30000 个字符)\n" stringByAppendingString:content];
    }
    UIPasteboard.generalPasteboard.string = content;
    PFLog(@"Diagnostic log copied to clipboard.");
    [self showMessage:@"诊断日志已复制到剪贴板。" title:@"PiggyHandFish"];
}

- (void)presentMenu {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self presentMenu]; });
        return;
    }

    UIViewController *top = [self topViewControllerFrom:self.hostWindow.rootViewController];
    if (!top) {
        [self installEntryWhenReady];
        return;
    }
    if (top.presentedViewController) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"PiggyHandFish"
                                                                   message:@"iOS 运行时侦察工具"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    // Build executable menu items from the Action registry.
    __weak typeof(self) weakSelf = self;
    for (PFAction *registeredAction in PFRegisteredActions()) {
        PFAction *action = registeredAction;
        NSString *buttonTitle = action.title;
        [sheet addAction:[UIAlertAction actionWithTitle:buttonTitle
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *alertAction) {
            PFPerformAction(action.identifier, ^(BOOL success, NSString *message) {
                [weakSelf showMessage:message title:(success ? buttonTitle : @"Action 执行失败")];
            });
        }]];
    }

    PFConfig *config = PFGetConfig();
    __weak typeof(self) weakSelf = self;
    [self addToggleActionToSheet:sheet title:@"类名日志" value:config.logClasses set:^(BOOL value) {
        PFGetConfig().logClasses = value;
    }];
    [self addToggleActionToSheet:sheet title:@"实例方法日志" value:config.logMethods set:^(BOOL value) {
        PFGetConfig().logMethods = value;
    }];
    [self addToggleActionToSheet:sheet title:@"类方法日志" value:config.logClassMethods set:^(BOOL value) {
        PFGetConfig().logClassMethods = value;
    }];

    [sheet addAction:[UIAlertAction actionWithTitle:@"查看运行状态" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf showMessage:[weakSelf statusMessage] title:@"运行状态"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制日志文件路径" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = PFPluginLogPath();
        [weakSelf showMessage:@"日志文件路径已复制。" title:@"PiggyHandFish"];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭面板" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.entryButton ?: top.view;
        popover.sourceRect = self.entryButton ? self.entryButton.bounds : CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [top presentViewController:sheet animated:YES completion:nil];
}

@end

void PFInstallPluginEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PFPluginEntryManager shared] start];
    });
}
