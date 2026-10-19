#import "PFScout.h"
#import "PFConfig.h"
#import "PFLogger.h"
#import <objc/runtime.h>
#import <stdlib.h>

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

static void PFLogMethodList(Class reportedClass,
                            Class methodOwner,
                            BOOL isClassMethod,
                            PFConfig *config) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(methodOwner, &count);
    NSUInteger emitted = 0;

    for (unsigned int i = 0; i < count && emitted < config.maxMethodsPerClass; i++) {
        SEL selector = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(selector);
        if (!PFMatches(name, config.methodRegex)) continue;

        const char *types = method_getTypeEncoding(methods[i]);
        PFLog(@"  method: %c[%s %@] types=%s",
              isClassMethod ? '+' : '-',
              class_getName(reportedClass),
              name,
              types ?: "(unknown)");
        emitted++;
    }

    free(methods);
}

static void PFLogMethods(Class cls, PFConfig *config) {
    if (config.logMethods) {
        PFLogMethodList(cls, cls, NO, config);
    }

    if (config.logClassMethods) {
        // Objective-C class methods are instance methods on the metaclass.
        Class metaClass = object_getClass(cls);
        if (metaClass) {
            PFLogMethodList(cls, metaClass, YES, config);
        }
    }
}

void PFStartScout(void) {
    PFConfig *config = PFGetConfig();
    if (!config.logClasses && !config.logMethods && !config.logClassMethods) {
        PFLog(@"Class, instance-method, and class-method logging are all disabled.");
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
        if (error || !classRegex) {
            PFLog(@"Invalid class regex '%@': %@", config.classRegex,
                  error.localizedDescription ?: @"unknown error");
            free(classes);
            return;
        }
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
        if (config.logMethods || config.logClassMethods) PFLogMethods(classes[i], config);
    }

    PFLog(@"Runtime scan complete. Total runtime classes: %d; matched classes: %lu",
          classCount, (unsigned long)matched);
    free(classes);
}
