#import "PFTaskModelProbe.h"
#import "PFLogger.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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

void PFInstallTaskModelProbe(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        PFLog(@"TASK_MODEL_PROBE installing read-only Android/iOS model comparison scan");
        PFScanTaskModelRuntime(@"startup");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PFScanTaskModelRuntime(@"delayed_5s");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PFScanTaskModelRuntime(@"delayed_15s");
        });
    });
}
