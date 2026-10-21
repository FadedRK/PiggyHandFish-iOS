#import "PFMtopBridge.h"
#import "PFLogger.h"
#import <objc/runtime.h>

static BOOL gPFMtopBridgeInstalled = NO;

static BOOL PFRelevantClassName(NSString *name) {
    NSString *n = name.lowercaseString;
    return [n containsString:@"mtop"] ||
           [n containsString:@"mtopsdk"] ||
           [n containsString:@"xmodule"] ||
           [n containsString:@"apiprotocol"] ||
           [n containsString:@"apirequest"] ||
           [n containsString:@"apisender"] ||
           [n containsString:@"mtoprequest"] ||
           [n containsString:@"mtopresponse"] ||
           [n containsString:@"signimpl"];
}

static void PFScanMtopClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    NSUInteger matched = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *rawName = class_getName(cls);
        if (!rawName) continue;
        NSString *name = [NSString stringWithUTF8String:rawName];
        if (!PFRelevantClassName(name)) continue;

        matched++;
        Class superclass = class_getSuperclass(cls);
        PFLog(@"MTOP_NATIVE_CLASS class=%@ superclass=%@",
              name,
              superclass ? NSStringFromClass(superclass) : @"(none)");

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSUInteger emitted = 0;
        for (unsigned int j = 0; j < methodCount && emitted < 80; j++) {
            SEL selector = method_getName(methods[j]);
            NSString *selName = NSStringFromSelector(selector);
            NSString *lower = selName.lowercaseString;
            if ([lower containsString:@"send"] ||
                [lower containsString:@"request"] ||
                [lower containsString:@"response"] ||
                [lower containsString:@"execute"] ||
                [lower containsString:@"start"] ||
                [lower containsString:@"finish"] ||
                [lower containsString:@"callback"] ||
                [lower containsString:@"api"] ||
                [lower containsString:@"param"] ||
                [lower containsString:@"sign"]) {
                PFLog(@"MTOP_NATIVE_METHOD class=%@ selector=%@ types=%s",
                      name, selName, method_getTypeEncoding(methods[j]));
                emitted++;
            }
        }
        free(methods);
    }

    PFLog(@"MTOP_NATIVE_SCAN_DONE totalClasses=%d matched=%lu",
          count, (unsigned long)matched);
    free(classes);
}

void PFInstallMtopBridge(void) {
    if (gPFMtopBridgeInstalled) return;
    gPFMtopBridgeInstalled = YES;

    PFLog(@"MTOP_NATIVE_BRIDGE installing read-only native MTOP class/method reconnaissance");
    PFScanMtopClasses();
    PFLog(@"MTOP_NATIVE_BRIDGE installed; no requests are modified or sent");
}
