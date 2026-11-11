#import "PFTaskModelProbe.h"
#import "PFLogger.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>

static __thread BOOL gPFTaskProbeFormattingLog = NO;
static os_unfair_lock gPFTaskProbeHookLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gPFTaskProbeInstalledHooks = nil;

static BOOL PFTaskModelCandidateSelector(NSString *selectorName) {
    NSString *s = selectorName.lowercaseString;
    NSArray<NSString *> *terms = @[
        @"delivery", @"scene", @"impl", @"action", @"task", @"progress",
        @"times", @"max", @"benefit", @"reward", @"claim", @"complete",
        @"finish", @"award", @"card", @"item", @"fresh", @"status", @"state"
    ];
    for (NSString *term in terms) {
        if ([s containsString:term]) return YES;
    }
    return NO;
}

static BOOL PFTaskModelCandidateClass(NSString *className) {
    NSString *s = className.lowercaseString;
    return [s isEqualToString:@"tbsdkserver"] ||
           [s isEqualToString:@"tbsdkmtopserver"] ||
           [s containsString:@"task"] ||
           [s containsString:@"oliver"] ||
           [s containsString:@"coin"];
}

static void PFScanTaskModelRuntime(NSString *reason) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    NSUInteger matchedClasses = 0;
    NSUInteger emittedMethods = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *rawName = class_getName(cls);
        if (!rawName) continue;
        NSString *className = [NSString stringWithUTF8String:rawName];
        if (!PFTaskModelCandidateClass(className)) continue;

        matchedClasses++;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j = 0; j < methodCount && emittedMethods < 500; j++) {
            Method method = methods[j];
            SEL selector = method_getName(method);
            NSString *selectorName = NSStringFromSelector(selector);
            if (!PFTaskModelCandidateSelector(selectorName)) continue;

            PFLog(@"TASK_MODEL_CANDIDATE reason=%@ class=%@ selector=%@ types=%s",
                  reason, className, selectorName,
                  method_getTypeEncoding(method) ?: "(unknown)");
            emittedMethods++;
        }
        free(methods);
        if (emittedMethods >= 500) break;
    }

    PFLog(@"TASK_MODEL_SCAN_DONE reason=%@ totalClasses=%d matchedClasses=%lu candidateMethods=%lu",
          reason, count, (unsigned long)matchedClasses, (unsigned long)emittedMethods);
    free(classes);
}

// Return only a Method implemented directly by cls. Never hook an inherited
// Method through class_getInstanceMethod, which could modify a superclass.
static Method PFFindOwnInstanceMethod(Class cls, SEL selector) {
    if (!cls || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return NULL;

    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

// This formatter deliberately avoids description, JSON serialization, custom
// getters, dictionary enumeration, and arbitrary object callbacks. Numeric
// reward values are revealed only for the two explicitly approved reward fields.
static NSString *PFSafeReadOnlyObjectTag(id object, BOOL allowRewardScalar) {
    if (!object) return @"(nil)";

    Class cls = object_getClass(object);
    const char *className = cls ? class_getName(cls) : "unknown";

    if ([object isKindOfClass:[NSNumber class]]) {
        if (allowRewardScalar) {
            NSString *number = [(NSNumber *)object stringValue];
            if (number.length <= 8) {
                return [NSString stringWithFormat:@"<%s:%p rewardScalar=%@>", className, object, number];
            }
        }
        return [NSString stringWithFormat:@"<%s:%p>", className, object];
    }

    if ([object isKindOfClass:[NSString class]]) {
        CFStringRef string = (__bridge CFStringRef)object;
        CFIndex length = CFStringGetLength(string);
        if (allowRewardScalar && length > 0 && length <= 8) {
            BOOL allDigits = YES;
            for (CFIndex i = 0; i < length; i++) {
                UniChar character = CFStringGetCharacterAtIndex(string, i);
                if (character < '0' || character > '9') {
                    allDigits = NO;
                    break;
                }
            }
            if (allDigits) {
                return [NSString stringWithFormat:@"<%s:%p len=%ld rewardScalar=%@>",
                        className, object, (long)length, (NSString *)object];
            }
        }
        return [NSString stringWithFormat:@"<%s:%p len=%ld>", className, object, (long)length];
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"<%s:%p dictionaryCount=%lu>",
                className, object, (unsigned long)[(NSDictionary *)object count]];
    }
    if ([object isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"<%s:%p arrayCount=%lu>",
                className, object, (unsigned long)[(NSArray *)object count]];
    }
    return [NSString stringWithFormat:@"<%s:%p>", className, object];
}

static void PFTaskProbeLogHit(NSString *definedIn,
                              id object,
                              NSString *selector,
                              NSString *detail) {
    if (gPFTaskProbeFormattingLog) return;
    gPFTaskProbeFormattingLog = YES;
    @try {
        PFLog(@"TASK_EXEC_HIT definedIn=%@ actualClass=%s self=%p selector=%@ %@",
              definedIn,
              object ? object_getClassName(object) : "nil",
              object,
              selector,
              detail ?: @"");
    } @finally {
        gPFTaskProbeFormattingLog = NO;
    }
}

static NSString *PFTaskHookKey(const char *className, const char *selectorName) {
    return [NSString stringWithFormat:@"%s::%s", className, selectorName];
}

static void PFInstallStrictReadOnlyHook(const char *className,
                                        const char *selectorName,
                                        const char *expectedExactEncoding) {
    if (!className || !selectorName || !expectedExactEncoding) return;

    Class cls = objc_getClass(className);
    if (!cls) {
        PFLog(@"TASK_HOOK_WAIT reason=class_not_loaded class=%s selector=%s", className, selectorName);
        return;
    }

    SEL selector = sel_registerName(selectorName);
    NSString *hookKey = PFTaskHookKey(className, selectorName);

    os_unfair_lock_lock(&gPFTaskProbeHookLock);
    if (!gPFTaskProbeInstalledHooks) {
        gPFTaskProbeInstalledHooks = [NSMutableSet set];
    }
    if ([gPFTaskProbeInstalledHooks containsObject:hookKey]) {
        os_unfair_lock_unlock(&gPFTaskProbeHookLock);
        return;
    }

    Method method = PFFindOwnInstanceMethod(cls, selector);
    if (!method) {
        os_unfair_lock_unlock(&gPFTaskProbeHookLock);
        PFLog(@"TASK_HOOK_SKIP reason=not_own_method class=%s selector=%s", className, selectorName);
        return;
    }

    const char *actualEncoding = method_getTypeEncoding(method);
    if (!actualEncoding || strcmp(actualEncoding, expectedExactEncoding) != 0) {
        os_unfair_lock_unlock(&gPFTaskProbeHookLock);
        PFLog(@"TASK_HOOK_SKIP reason=encoding_mismatch class=%s selector=%s actual=%s expected=%s",
              className, selectorName,
              actualEncoding ?: "(null)", expectedExactEncoding);
        return;
    }

    IMP originalIMP = method_getImplementation(method);
    if (!originalIMP) {
        os_unfair_lock_unlock(&gPFTaskProbeHookLock);
        PFLog(@"TASK_HOOK_SKIP reason=missing_imp class=%s selector=%s", className, selectorName);
        return;
    }

    NSString *definedIn = [NSString stringWithUTF8String:className];
    NSString *selectorText = [NSString stringWithUTF8String:selectorName];
    BOOL allowRewardScalar = [selectorText isEqualToString:@"rewardAmount"] ||
                             [selectorText isEqualToString:@"setRewardAmount:"] ||
                             [selectorText isEqualToString:@"rewardDuration"] ||
                             [selectorText isEqualToString:@"setRewardDuration:"];
    IMP replacement = NULL;

    // Objective-C encoding is checked byte-for-byte before selecting an ABI wrapper.
    if (strcmp(expectedExactEncoding, "v16@0:8") == 0) {
        typedef void (*Function)(id, SEL);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^(id selfObject) {
            PFTaskProbeLogHit(definedIn, selfObject, selectorText, @"voidCall=1");
            original(selfObject, selector);
        });
    } else if (strcmp(expectedExactEncoding, "B16@0:8") == 0) {
        typedef BOOL (*Function)(id, SEL);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^BOOL(id selfObject) {
            BOOL result = original(selfObject, selector);
            PFTaskProbeLogHit(definedIn, selfObject, selectorText,
                              [NSString stringWithFormat:@"boolResult=%d", (int)result]);
            return result;
        });
    } else if (strcmp(expectedExactEncoding, "v20@0:8B16") == 0) {
        typedef void (*Function)(id, SEL, BOOL);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^(id selfObject, BOOL argument) {
            PFTaskProbeLogHit(definedIn, selfObject, selectorText,
                              [NSString stringWithFormat:@"boolArg=%d", (int)argument]);
            original(selfObject, selector, argument);
        });
    } else if (strcmp(expectedExactEncoding, "d16@0:8") == 0) {
        typedef double (*Function)(id, SEL);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^double(id selfObject) {
            double result = original(selfObject, selector);
            PFTaskProbeLogHit(definedIn, selfObject, selectorText, @"doubleResultObserved=1");
            return result;
        });
    } else if (strcmp(expectedExactEncoding, "v24@0:8d16") == 0) {
        typedef void (*Function)(id, SEL, double);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^(id selfObject, double argument) {
            (void)argument;
            PFTaskProbeLogHit(definedIn, selfObject, selectorText, @"doubleArgObserved=1");
            original(selfObject, selector, argument);
        });
    } else if (strcmp(expectedExactEncoding, "@16@0:8") == 0) {
        typedef id (*Function)(id, SEL);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^id(id selfObject) {
            id result = original(selfObject, selector);
            NSString *tag = PFSafeReadOnlyObjectTag(result, allowRewardScalar);
            PFTaskProbeLogHit(definedIn, selfObject, selectorText,
                              [NSString stringWithFormat:@"objectResult=%@", tag]);
            return result;
        });
    } else if (strcmp(expectedExactEncoding, "v24@0:8@16") == 0) {
        typedef void (*Function)(id, SEL, id);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^(id selfObject, id argument) {
            NSString *tag = PFSafeReadOnlyObjectTag(argument, allowRewardScalar);
            PFTaskProbeLogHit(definedIn, selfObject, selectorText,
                              [NSString stringWithFormat:@"objectArg=%@", tag]);
            original(selfObject, selector, argument);
        });
    } else if (strcmp(expectedExactEncoding, "@24@0:8@16") == 0) {
        typedef id (*Function)(id, SEL, id);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^id(id selfObject, id argument) {
            id result = original(selfObject, selector, argument);
            NSString *argTag = PFSafeReadOnlyObjectTag(argument, NO);
            NSString *resultTag = PFSafeReadOnlyObjectTag(result, NO);
            PFTaskProbeLogHit(definedIn, selfObject, selectorText,
                              [NSString stringWithFormat:@"cfg=%@ result=%@", argTag, resultTag]);
            return result;
        });
    } else if (strcmp(expectedExactEncoding, "i24@0:8@16") == 0) {
        typedef int (*Function)(id, SEL, id);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^int(id selfObject, id argument) {
            int result = original(selfObject, selector, argument);
            NSString *argTag = PFSafeReadOnlyObjectTag(argument, NO);
            PFTaskProbeLogHit(definedIn, selfObject, selectorText,
                              [NSString stringWithFormat:@"arg=%@ intResult=%d", argTag, result]);
            return result;
        });
    } else if (strcmp(expectedExactEncoding, "B32@0:8@16@24") == 0) {
        typedef BOOL (*Function)(id, SEL, id, id);
        Function original = (Function)originalIMP;
        replacement = imp_implementationWithBlock(^BOOL(id selfObject, id argument1, id argument2) {
            BOOL result = original(selfObject, selector, argument1, argument2);
            NSString *arg1Tag = PFSafeReadOnlyObjectTag(argument1, NO);
            NSString *arg2Tag = PFSafeReadOnlyObjectTag(argument2, NO);
            PFTaskProbeLogHit(definedIn, selfObject, selectorText,
                              [NSString stringWithFormat:@"arg1=%@ arg2=%@ boolResult=%d",
                               arg1Tag, arg2Tag, (int)result]);
            return result;
        });
    }

    if (!replacement) {
        os_unfair_lock_unlock(&gPFTaskProbeHookLock);
        PFLog(@"TASK_HOOK_SKIP reason=unsupported_encoding class=%s selector=%s encoding=%s",
              className, selectorName, expectedExactEncoding);
        return;
    }

    method_setImplementation(method, replacement);
    [gPFTaskProbeInstalledHooks addObject:hookKey];
    os_unfair_lock_unlock(&gPFTaskProbeHookLock);

    PFLog(@"TASK_HOOK_INSTALLED class=%s selector=%s encoding=%s",
          className, selectorName, expectedExactEncoding);
}

static void PFInstallTargetedTaskExecutionProbes(NSString *reason) {
    PFLog(@"TASK_HOOK_PASS reason=%@", reason);

    // Candidate A: possible mall-browse controller. Runtime calls, not class
    // naming, must establish whether it participates in the target task.
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "lastMallTapTimestamp", "d16@0:8");
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "resetScrollObservationState", "v16@0:8");
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "scrollInteractionActive", "B16@0:8");
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "setLastMallTapTimestamp:", "v24@0:8d16");
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "setScrollInteractionActive:", "v20@0:8B16");
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "finished", "B16@0:8");
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "setFinished:", "v20@0:8B16");
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "refresh", "v16@0:8");
    PFInstallStrictReadOnlyHook("FMFACsjMallBrowseTaskController", "finish", "v16@0:8");

    // Candidate B: names suggest ad-query configuration; values are exposed
    // only for rewardAmount/rewardDuration and only as short numeric scalars.
    PFInstallStrictReadOnlyHook("FMFAAdQueryBrowseTaskConfigModel", "rewardAmount", "@16@0:8");
    PFInstallStrictReadOnlyHook("FMFAAdQueryBrowseTaskConfigModel", "rewardDuration", "@16@0:8");
    PFInstallStrictReadOnlyHook("FMFAAdQueryBrowseTaskConfigModel", "rewardName", "@16@0:8");
    PFInstallStrictReadOnlyHook("FMFAAdQueryBrowseTaskConfigModel", "setRewardAmount:", "v24@0:8@16");
    PFInstallStrictReadOnlyHook("FMFAAdQueryBrowseTaskConfigModel", "setRewardDuration:", "v24@0:8@16");
    PFInstallStrictReadOnlyHook("FMFAAdQueryBrowseTaskConfigModel", "setRewardName:", "v24@0:8@16");

    // Candidate C: generic task parsers. Configuration payload contents are
    // never serialized; only object class/pointer/count metadata is observed.
    PFInstallStrictReadOnlyHook("UEPBaseTaskParser", "createTaskWithCfg:", "@24@0:8@16");
    PFInstallStrictReadOnlyHook("CEPTaskParser", "getTaskTrigger:", "i24@0:8@16");
    PFInstallStrictReadOnlyHook("CEPTaskParser", "createPatterns:task:", "B32@0:8@16@24");
    PFInstallStrictReadOnlyHook("CEPTaskParser", "createTaskWithCfg:", "@24@0:8@16");
    PFInstallStrictReadOnlyHook("SSPTaskParser", "createOperators:task:", "B32@0:8@16@24");
    PFInstallStrictReadOnlyHook("SSPTaskParser", "createTaskWithCfg:", "@24@0:8@16");
}

void PFInstallTaskModelProbe(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        PFLog(@"TASK_MODEL_PROBE installing read-only runtime metadata and execution observation");
        PFScanTaskModelRuntime(@"startup");
        PFInstallTargetedTaskExecutionProbes(@"startup");

        // Some host classes may be registered lazily after the dylib constructor.
        // Re-scan and retry missing hooks a few times; successfully installed
        // hooks are idempotently skipped by the installed-hook set.
        NSArray<NSNumber *> *delays = @[@2.0, @5.0, @15.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSString *reason = [NSString stringWithFormat:@"delayed_%.0fs", delay.doubleValue];
                PFScanTaskModelRuntime(reason);
                PFInstallTargetedTaskExecutionProbes(reason);
            });
        }
    });
}
