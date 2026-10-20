#import "PFAction.h"
#import <UIKit/UIKit.h>
#import "PFLogger.h"
#import "PFScout.h"
#import <dispatch/dispatch.h>

static NSString *PFActionLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish.log"];
}

typedef void (^PFActionHandler)(PFActionCompletion completion);

@interface PFAction ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *detail;
@property (nonatomic, copy) PFActionHandler handler;
+ (instancetype)actionWithIdentifier:(NSString *)identifier
                                title:(NSString *)title
                               detail:(NSString *)detail
                              handler:(PFActionHandler)handler;
@end

@implementation PFAction
+ (instancetype)actionWithIdentifier:(NSString *)identifier
                                title:(NSString *)title
                               detail:(NSString *)detail
                              handler:(PFActionHandler)handler {
    PFAction *action = [PFAction new];
    action.identifier = identifier;
    action.title = title;
    action.detail = detail;
    action.handler = handler;
    return action;
}
@end

NSArray<PFAction *> *PFRegisteredActions(void) {
    static NSArray<PFAction *> *actions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        PFAction *openFishCoin = [PFAction actionWithIdentifier:@"open_fish_coin_entry"
            title:@"打开闲鱼鱼币任务页"
            detail:@"通过闲鱼自身的深链打开对应页面，由用户自行操作。"
            handler:^(PFActionCompletion completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSURL *url = [NSURL URLWithString:
                        @"fleamarket://fish_coin_game?flutter=true&is_business_shop_game=true&showTask=true&channel=mainpage"];
                    if (!url) {
                        if (completion) completion(NO, @"鱼币页面地址无效。");
                        return;
                    }
                    if (@available(iOS 10.0, *)) {
                        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
                            if (completion) {
                                completion(success,
                                    success ? @"已请求闲鱼打开鱼币任务页，请在闲鱼界面继续操作。"
                                            : @"闲鱼未接受该链接；请确认当前版本是否支持此入口。");
                            }
                        }];
                    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        BOOL success = [UIApplication.sharedApplication openURL:url];
#pragma clang diagnostic pop
                        if (completion) {
                            completion(success, success ? @"已请求闲鱼打开鱼币任务页。" : @"闲鱼未接受该链接。");
                        }
                    }
                });
            }];

        PFAction *runScout = [PFAction actionWithIdentifier:@"run_recon"
            title:@"运行 Runtime 侦察"
            detail:@"在后台枚举匹配的 Objective-C 类和方法。"
            handler:^(PFActionCompletion completion) {
                PFLog(@"Action requested: run_recon");
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    PFStartScout();
                    if (completion) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completion(YES, @"侦察扫描已执行。请查看或复制诊断日志。");
                        });
                    }
                });
            }];

        PFAction *copyLog = [PFAction actionWithIdentifier:@"copy_diagnostics"
            title:@"复制诊断日志"
            detail:@"复制日志文件最近的诊断内容到剪贴板。"
            handler:^(PFActionCompletion completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *error = nil;
                    NSString *content = [NSString stringWithContentsOfFile:PFActionLogPath()
                                                                   encoding:NSUTF8StringEncoding
                                                                      error:&error];
                    if (!content) {
                        if (completion) completion(NO, error.localizedDescription ?: @"日志文件尚不存在，请先运行侦察。");
                        return;
                    }
                    const NSUInteger maxCharacters = 30000;
                    if (content.length > maxCharacters) {
                        content = [content substringFromIndex:content.length - maxCharacters];
                        content = [@"(仅复制最近 30000 个字符)\n" stringByAppendingString:content];
                    }
                    UIPasteboard.generalPasteboard.string = content;
                    if (completion) completion(YES, @"诊断日志已复制到剪贴板。");
                });
            }];

        PFAction *clearLog = [PFAction actionWithIdentifier:@"clear_diagnostics"
            title:@"清空诊断日志"
            detail:@"清空本插件在当前 App 临时目录中保存的日志文件。"
            handler:^(PFActionCompletion completion) {
                NSError *error = nil;
                BOOL success = [@"" writeToFile:PFActionLogPath()
                                      atomically:YES
                                        encoding:NSUTF8StringEncoding
                                           error:&error];
                if (completion) {
                    completion(success, success ? @"诊断日志已清空。" :
                               (error.localizedDescription ?: @"清空日志失败。"));
                }
            }];

        PFAction *logStatus = [PFAction actionWithIdentifier:@"log_runtime_status"
            title:@"记录运行状态"
            detail:@"把当前 Bundle、版本信息写入诊断日志。"
            handler:^(PFActionCompletion completion) {
                NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)";
                NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"(unknown)";
                PFLog(@"Action runtime status: bundle=%@ version=%@", bundle, version);
                if (completion) completion(YES, @"运行状态已写入诊断日志。");
            }];

        actions = @[openFishCoin, runScout, copyLog, clearLog, logStatus];
    });
    return actions;
}

void PFPerformAction(NSString *identifier, PFActionCompletion completion) {
    if (identifier.length == 0) {
        if (completion) completion(NO, @"Action ID 不能为空。");
        return;
    }

    PFAction *matched = nil;
    for (PFAction *action in PFRegisteredActions()) {
        if ([action.identifier isEqualToString:identifier]) {
            matched = action;
            break;
        }
    }

    if (!matched || !matched.handler) {
        if (completion) completion(NO, [NSString stringWithFormat:@"未注册的 Action：%@", identifier]);
        return;
    }

    PFLog(@"Action started: %@ (%@)", matched.identifier, matched.title);
    matched.handler(completion);
}
