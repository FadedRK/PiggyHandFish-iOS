#import "PFTaskAssistant.h"
#import "PFLogger.h"
#import "PFFishTaskRules.h"
#import "PFMtopBridge.h"
#import <os/lock.h>

static os_unfair_lock gPFAssistantLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSDictionary *> *gPFAssistantTasks;
static NSMutableSet<NSString *> *gPFAssistantImplRefs;
static NSDate *gPFAssistantLastListAt;
static NSString *gPFAssistantLastAPI;
static NSString *gPFAssistantLastRet;
static NSString *gPFAssistantLastCorrelation;
static NSUInteger gPFAssistantListRefreshes;
static NSUInteger gPFAssistantClickEvents;
static NSUInteger gPFAssistantProgressChanges;
static NSUInteger gPFAssistantFailures;

static NSString *PFAString(id value) {
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    return @"";
}

static NSString *PFACompactText(NSString *value, NSUInteger limit) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    NSString *clean = [[value componentsSeparatedByCharactersInSet:
                        [NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length > limit) clean = [[clean substringToIndex:limit] stringByAppendingString:@"…"];
    return clean;
}

static NSString *PFARetCode(NSDictionary *response) {
    id raw = response[@"ret"];
    NSString *candidate = nil;
    if ([raw isKindOfClass:[NSArray class]] && [(NSArray *)raw count] > 0) {
        candidate = PFAString([(NSArray *)raw firstObject]);
    } else if ([raw isKindOfClass:[NSString class]]) {
        candidate = (NSString *)raw;
    }
    if (candidate.length == 0) return @"(无 ret)";
    candidate = [[candidate componentsSeparatedByString:@"::"] firstObject];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-"];
    if (candidate.length > 48 ||
        [candidate rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        return @"(已隐藏)";
    }
    return candidate;
}

static NSString *PFAKindName(PFFishTaskKind kind) {
    switch (kind) {
        case PFFishTaskKindClaim: return @"待领奖";
        case PFFishTaskKindGoodItemClick: return @"点击好物";
        case PFFishTaskKindSearch: return @"搜索";
        case PFFishTaskKindBrowse: return @"浏览";
        case PFFishTaskKindECMallAd: return @"商城浏览";
        case PFFishTaskKindTreasure: return @"寻宝";
        case PFFishTaskKindTrigger: return @"普通任务";
        default: return @"其他";
    }
}

static NSString *PFAStatusName(PFFishTask *task) {
    if ([task.status isEqualToString:@"AWARD"]) return @"待领取";
    if ([task.status isEqualToString:@"COMPLETE"]) {
        return task.needBenefit ? @"已完成·待领取" : @"已完成";
    }
    if ([task.status isEqualToString:@"ACCEPTED"]) return @"待完成";
    if (task.status.length) return task.status;
    return @"未知";
}

static NSString *PFAImplRefFromCorrelation(NSString *correlation) {
    if (![correlation isKindOfClass:[NSString class]]) return @"";
    for (NSString *part in [correlation componentsSeparatedByString:@" "]) {
        if ([part hasPrefix:@"implRef="]) return [part substringFromIndex:8];
    }
    return @"";
}

static NSString *PFATaskRef(NSString *sceneID, NSString *deliveryID) {
    NSString *ref = PFTaskReferenceForIdentifiers(sceneID.length ? sceneID : @"496", deliveryID);
    return ref.length ? ref : @"";
}

void PFTaskAssistantConsumeResponse(NSString *apiName,
                                    NSDictionary *response,
                                    NSString *requestCorrelation) {
    if (![apiName isKindOfClass:[NSString class]] ||
        ![response isKindOfClass:[NSDictionary class]]) return;

    NSString *api = apiName.lowercaseString;
    NSString *ret = PFARetCode(response);
    BOOL isTaskList = [api isEqualToString:PFFishTaskListAPI.lowercaseString];
    BOOL isTaskDetail = [api containsString:@"getolivertaskdetail"];
    BOOL isTaskBenefit = [api containsString:@"getolivertaskbenefit"];
    BOOL isTaskTrigger = [api containsString:@"uploadolivertasktrigger"];
    BOOL isPentaprism = [api isEqualToString:@"mtop.taobao.pentaprism.scene.trigger"];
    if (!(isTaskList || isTaskDetail || isTaskBenefit || isTaskTrigger || isPentaprism)) return;

    NSString *eventName = isTaskList ? @"任务列表" :
                          isTaskDetail ? @"任务详情" :
                          isTaskBenefit ? @"领奖接口" :
                          isTaskTrigger ? @"任务触发接口" : @"商品点击事件";

    if (isTaskList) {
        NSArray<PFFishTask *> *tasks = PFFishParseTaskListResponse(response);
        NSMutableDictionary<NSString *, NSDictionary *> *next = [NSMutableDictionary dictionary];
        NSUInteger changed = 0;
        for (PFFishTask *task in tasks) {
            NSString *taskRef = PFATaskRef(task.sceneID, task.deliveryID);
            if (taskRef.length == 0) continue;

            NSString *key = taskRef;
            NSDictionary *snapshot = @{
                @"taskRef": taskRef,
                @"title": PFACompactText(task.title, 64),
                @"status": task.status ?: @"",
                @"statusName": PFAStatusName(task),
                @"kind": PFAKindName(task.kind),
                @"times": @(MAX(0, task.times)),
                @"maxTimes": @(MAX(0, task.maxTimes)),
                @"needBenefit": @(task.needBenefit),
            };
            os_unfair_lock_lock(&gPFAssistantLock);
            NSDictionary *previous = gPFAssistantTasks[key];
            NSInteger oldTimes = [previous[@"times"] integerValue];
            NSInteger newTimes = [snapshot[@"times"] integerValue];
            if (previous && newTimes > oldTimes) changed++;
            os_unfair_lock_unlock(&gPFAssistantLock);
            next[key] = snapshot;
        }

        os_unfair_lock_lock(&gPFAssistantLock);
        gPFAssistantTasks = next;
        gPFAssistantLastListAt = [NSDate date];
        gPFAssistantLastAPI = apiName;
        gPFAssistantLastRet = ret;
        gPFAssistantLastCorrelation = requestCorrelation ?: @"";
        gPFAssistantListRefreshes++;
        gPFAssistantProgressChanges += changed;
        os_unfair_lock_unlock(&gPFAssistantLock);

        PFLog(@"TASK_ASSISTANT list_snapshot tasks=%lu progressChanges=%lu ret=%@",
              (unsigned long)tasks.count, (unsigned long)changed, ret);
        return;
    }

    os_unfair_lock_lock(&gPFAssistantLock);
    gPFAssistantLastAPI = apiName;
    gPFAssistantLastRet = ret;
    gPFAssistantLastCorrelation = requestCorrelation ?: @"";
    if (isPentaprism) {
        gPFAssistantClickEvents++;
        NSString *implRef = PFAImplRefFromCorrelation(requestCorrelation);
        if (implRef.length && ![implRef isEqualToString:@"(none)"]) {
            if (!gPFAssistantImplRefs) gPFAssistantImplRefs = [NSMutableSet set];
            [gPFAssistantImplRefs addObject:implRef];
        }
    }
    os_unfair_lock_unlock(&gPFAssistantLock);

    // A successful transport/delegate callback is not treated as task completion
    // or a confirmed coin credit. The refreshed task-list response remains the
    // source of truth for status and progress snapshots.
    PFLog(@"TASK_ASSISTANT event=%@ ret=%@ correlation={%@}",
          eventName, ret, requestCorrelation.length ? requestCorrelation : @"(none)");
}

void PFTaskAssistantRecordFailure(NSString *apiName, NSString *requestCorrelation) {
    if (![apiName isKindOfClass:[NSString class]]) return;
    NSString *api = apiName.lowercaseString;
    if (![api hasPrefix:@"mtop.taobao.idle.task."] &&
        ![api isEqualToString:@"mtop.taobao.pentaprism.scene.trigger"]) return;

    os_unfair_lock_lock(&gPFAssistantLock);
    gPFAssistantFailures++;
    gPFAssistantLastAPI = apiName;
    gPFAssistantLastRet = @"delegate_failure";
    gPFAssistantLastCorrelation = requestCorrelation ?: @"";
    os_unfair_lock_unlock(&gPFAssistantLock);

    PFLog(@"TASK_ASSISTANT delegate_failure api=%@ correlation={%@}",
          apiName, requestCorrelation.length ? requestCorrelation : @"(none)");
}

NSString *PFTaskAssistantFormattedSummary(void) {
    os_unfair_lock_lock(&gPFAssistantLock);
    NSDictionary<NSString *, NSDictionary *> *snapshots = [gPFAssistantTasks copy] ?: @{};
    NSDate *lastListAt = gPFAssistantLastListAt;
    NSString *lastAPI = [gPFAssistantLastAPI copy] ?: @"(尚无)";
    NSString *lastRet = [gPFAssistantLastRet copy] ?: @"(尚无)";
    NSString *lastCorrelation = [gPFAssistantLastCorrelation copy] ?: @"(none)";
    NSUInteger refreshes = gPFAssistantListRefreshes;
    NSUInteger clicks = gPFAssistantClickEvents;
    NSUInteger implCount = gPFAssistantImplRefs.count;
    NSUInteger progressChanges = gPFAssistantProgressChanges;
    NSUInteger failures = gPFAssistantFailures;
    os_unfair_lock_unlock(&gPFAssistantLock);

    if (snapshots.count == 0) {
        return @"PiggyHandFish v0.1 · 任务识别\n\n尚未捕获任务列表。\n请先通过闲鱼原生页面打开鱼币任务页，等待任务列表正常加载，再返回查看。\n\n本模块只观察闲鱼自身请求，不会主动发送任务请求。";
    }

    NSUInteger pending = 0, claimable = 0, completed = 0, other = 0;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSArray<NSString *> *refs = [[snapshots allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *ref in refs) {
        NSDictionary *task = snapshots[ref];
        NSString *status = task[@"status"];
        if ([status isEqualToString:@"AWARD"] ||
            ([status isEqualToString:@"COMPLETE"] && [task[@"needBenefit"] boolValue])) {
            claimable++;
        } else if ([status isEqualToString:@"ACCEPTED"]) {
            pending++;
        } else if ([status isEqualToString:@"COMPLETE"]) {
            completed++;
        } else {
            other++;
        }

        NSString *title = [task[@"title"] length] ? task[@"title"] : @"(无任务标题)";
        NSInteger times = [task[@"times"] integerValue];
        NSInteger maxTimes = [task[@"maxTimes"] integerValue];
        NSString *progress = maxTimes > 0
            ? [NSString stringWithFormat:@" · %ld/%ld", (long)times, (long)maxTimes]
            : @"";
        [lines addObject:[NSString stringWithFormat:@"%@ · %@ · %@ · %@%@",
                          ref, title, task[@"kind"], task[@"statusName"], progress]];
    }

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"MM-dd HH:mm:ss";
    NSString *time = lastListAt ? [formatter stringFromDate:lastListAt] : @"(无)";
    NSMutableString *summary = [NSMutableString stringWithFormat:
        @"PiggyHandFish v0.1 · 任务识别\n\n最近任务列表：%@\n刷新次数：%lu\n任务总数：%lu\n待完成：%lu · 待领取：%lu · 已完成：%lu · 其他：%lu\n\n商品场景事件：%lu 次（仅代表观察到接口回调，不代表有效计数）\n不同 implRef：%lu\n观察到进度增加：%lu 次\nMTOP delegate failure：%lu\n最近接口：%@\n最近 ret：%@\n最近关联：%@\n\n",
        time, (unsigned long)refreshes, (unsigned long)snapshots.count,
        (unsigned long)pending, (unsigned long)claimable, (unsigned long)completed,
        (unsigned long)other, (unsigned long)clicks, (unsigned long)implCount,
        (unsigned long)progressChanges, (unsigned long)failures,
        lastAPI, lastRet, lastCorrelation];

    [summary appendString:[lines componentsJoinedByString:@"\n"]];
    if (summary.length > 3600) {
        summary = [[summary substringToIndex:3500] mutableCopy];
        [summary appendString:@"\n…（任务较多，已截断）"];
    }
    return summary;
}
