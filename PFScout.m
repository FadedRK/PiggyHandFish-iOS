#import "PFScout.h"
#import "PFConfig.h"
#import "PFLogger.h"
#import <objc/runtime.h>

static BOOL PFMatches(NSString *text, NSString *pattern) {
    if (pattern.length == 0) return YES;

    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                          options:0
                                                                            error:&error];
    if (error || !regex) {
        PFLog(@"Invalid regex '%@': %@", pattern, error.localizedDescription ?: @"unknown error");
        return NO;
    }
    return [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

static void PFLogMethods(Class cls, PFConfig *config) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSUInteger emitted = 0;

    for (unsigned int i = 0; i < count && emitted < config.maxMethodsPerClass; i++) {
        SEL selector = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(selector);
        if (!PFMatches(name, config.methodRegex)) continue;

        PFLog(@"  method: -[%s %@] types=%s",
              class_getName(cls), name, method_getTypeEncoding(methods[i]));
        emitted++;
    }
    free(methods);
}

void PFStartScout(void) {
    PFConfig *config = PFGetConfig();
    if (!config.logClasses && !config.logMethods) {
        PFLog(@"Class and method logging are both disabled.");
        return;
    }

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        PFLog(@"Objective-C runtime returned no classes.");
        return;
    }

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) {
        PFLog(@"Could not allocate runtime class list.");
        return;
    }
    classCount = objc_getClassList(classes, classCount);

    NSRegularExpression *classRegex = nil;
    if (config.classRegex.length > 0) {
        NSError *error = nil;
        classRegex = [NSRegularExpression regularExpressionWithPattern:config.classRegex
                                                               options:0
                                                                 error:&error];
        if (error) PFLog(@"Invalid class regex '%@': %@", config.classRegex, error.localizedDescription);
    }

    NSUInteger matched = 0;
    for (int i = 0; i < classCount && matched < config.maxClasses; i++) {
        const char *rawName = class_getName(classes[i]);
        if (!rawName) continue;
        NSString *name = [NSString stringWithUTF8String:rawName];
        if (!name) continue;

        BOOL match = (classRegex == nil) ||
            ([classRegex firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil);
        if (!match) continue;

        matched++;
        if (config.logClasses) PFLog(@"class: %s", rawName);
        if (config.logMethods) PFLogMethods(classes[i], config);
    }

    PFLog(@"Runtime scan complete. Total runtime classes: %d; matched classes: %lu",
          classCount, (unsigned long)matched);
    free(classes);
}
