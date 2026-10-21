#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static BOOL gProbeAlertPresented = NO;
static BOOL gProbeRetryScheduled = NO;
static NSUInteger gProbeRetryCount = 0;
static id gProbeActiveObserver = nil;
static NSObject *gProbeLogLock = nil;

static NSObject *PFProbeLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gProbeLogLock = [NSObject new];
    });
    return gProbeLogLock;
}

static NSString *PFProbeLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish-load-probe.log"];
}

static void PFProbeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format ?: @"" arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [PiggyHandFish-LoadProbe] %@\n", [NSDate date], message ?: @""];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    @synchronized (PFProbeLock()) {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *path = PFProbeLogPath();
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *exception) {
        } @finally {
            [handle closeFile];
        }
    }
}

static UIViewController *PFProbeTopController(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *keyWindow = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
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
        if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
            if (visible) {
                controller = visible;
                continue;
            }
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
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

static void PFProbePresentAlertWhenReady(void);

static void PFProbeScheduleRetry(void) {
    if (gProbeAlertPresented || gProbeRetryScheduled || gProbeRetryCount >= 60) return;
    gProbeRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gProbeRetryScheduled = NO;
        gProbeRetryCount++;
        PFProbePresentAlertWhenReady();
    });
}

static void PFProbePresentAlertWhenReady(void) {
    if (gProbeAlertPresented) return;

    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) {
        PFProbeScheduleRetry();
        return;
    }

    UIViewController *presenter = PFProbeTopController();
    if (!presenter || !presenter.isViewLoaded || !presenter.view.window ||
        presenter.presentedViewController || [presenter isKindOfClass:UIAlertController.class]) {
        PFProbeScheduleRetry();
        return;
    }

    gProbeAlertPresented = YES;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)";
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"(unknown)";
    NSString *message = [NSString stringWithFormat:
        @"The dylib constructor executed successfully.\n\nBundle: %@\nVersion: %@\n\nLog: %@",
        bundle, version, PFProbeLogPath()];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"PiggyHandFish Load Probe"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        PFProbeLog(@"PROBE_ALERT_DISMISSED_BY_USER");
    }]];

    [presenter presentViewController:alert animated:YES completion:^{
        PFProbeLog(@"PROBE_ALERT_PRESENTED bundle=%@ version=%@", bundle, version);
    }];
}

static void PFProbeStartOnMainThread(void) {
    PFProbeLog([NSString stringWithFormat:
                @"CONSTRUCTOR_EXECUTED bundle=%@ version=%@ state=%ld log=%@",
                NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)",
                [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"(unknown)",
                (long)UIApplication.sharedApplication.applicationState,
                PFProbeLogPath()]);

    if (!gProbeActiveObserver) {
        gProbeActiveObserver =
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                             object:nil
                                                              queue:NSOperationQueue.mainQueue
                                                         usingBlock:^(__unused NSNotification *notification) {
            PFProbeLog(@"APPLICATION_DID_BECOME_ACTIVE");
            gProbeRetryCount = 0;
            PFProbeScheduleRetry();
        }];
    }

    PFProbePresentAlertWhenReady();
}

__attribute__((constructor))
static void PiggyHandFishLoadProbeInitialize(void) {
    NSLog(@"[PiggyHandFish-LoadProbe] dylib constructor executed");
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            PFProbeStartOnMainThread();
        }
    });
}
