#import "PFMtopBridge.h"
#import "PFLogger.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL gPFMtopBridgeInstalled = NO;
static BOOL gPFMtopBridgeObserversInstalled = NO;
static BOOL gFMTablePageMtopHooksInstalled = NO;

static id (*PFOriginalFMRequestApiName)(id, SEL);
static id (*PFOriginalFMRequestApiParameter)(id, SEL, BOOL);
static void (*PFOriginalFMHandleResponse)(id, SEL, BOOL, id, id, id, BOOL, BOOL);

static NSString *PFObjectClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"(nil)";
}

static NSString *PFDictionaryKeysDescription(id object) {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return PFObjectClassName(object);
    }
    NSArray *keys = [[(NSDictionary *)object allKeys] valueForKey:@"description"];
    return [NSString stringWithFormat:@"%@ keys=%@", PFObjectClassName(object), keys ?: @[]];
}

static id PFHookedFMRequestApiName(id self, SEL _cmd) {
    id result = PFOriginalFMRequestApiName ? PFOriginalFMRequestApiName(self, _cmd) : nil;
    PFLog(@"MTOP_OBSERVED_REQUEST_API_NAME class=%@ api=%@",
          NSStringFromClass([self class]), result ?: @"(nil)");
    return result;
}

static id PFHookedFMRequestApiParameter(id self, SEL _cmd, BOOL isPrefetch) {
    id result = PFOriginalFMRequestApiParameter ? PFOriginalFMRequestApiParameter(self, _cmd, isPrefetch) : nil;
    PFLog(@"MTOP_OBSERVED_REQUEST_API_PARAM class=%@ prefetch=%d param=%@",
          NSStringFromClass([self class]), isPrefetch, PFDictionaryKeysDescription(result));
    return result;
}

static void PFHookedFMHandleResponse(id self, SEL _cmd, BOOL success, id data, id error, id requestModel, BOOL refresh, BOOL atLaunch) {
    PFLog(@"MTOP_OBSERVED_RESPONSE class=%@ success=%d data=%@ errorClass=%@ requestClass=%@ refresh=%d atLaunch=%d",
          NSStringFromClass([self class]),
          success,
          PFDictionaryKeysDescription(data),
          PFObjectClassName(error),
          PFObjectClassName(requestModel),
          refresh,
          atLaunch);

    if (PFOriginalFMHandleResponse) {
        PFOriginalFMHandleResponse(self, _cmd, success, data, error, requestModel, refresh, atLaunch);
    }
}

static void PFInstallFMTablePageMtopHooks(void) {
    if (gFMTablePageMtopHooksInstalled) return;

    Class cls = NSClassFromString(@"FMTablePageMtop");
    if (!cls) return;

    Method nameMethod = class_getInstanceMethod(cls, @selector(requestApiName));
    Method paramMethod = class_getInstanceMethod(cls, @selector(requestApiParameter:));
    Method responseMethod = class_getInstanceMethod(cls, @selector(_handleResponseResultWithSuccess:data:error:mtopRequestModel:refresh:atLaunch:));

    if (!nameMethod || !paramMethod || !responseMethod) {
        PFLog(@"MTOP_FM_TABLE_HOOK_WAIT class=%@ name=%d param=%d response=%d",
              NSStringFromClass(cls), nameMethod != NULL, paramMethod != NULL, responseMethod != NULL);
        return;
    }

    PFOriginalFMRequestApiName = (id (*)(id, SEL))method_getImplementation(nameMethod);
    method_setImplementation(nameMethod, (IMP)PFHookedFMRequestApiName);

    PFOriginalFMRequestApiParameter = (id (*)(id, SEL, BOOL))method_getImplementation(paramMethod);
    method_setImplementation(paramMethod, (IMP)PFHookedFMRequestApiParameter);

    PFOriginalFMHandleResponse = (void (*)(id, SEL, BOOL, id, id, id, BOOL, BOOL))method_getImplementation(responseMethod);
    method_setImplementation(responseMethod, (IMP)PFHookedFMHandleResponse);

    gFMTablePageMtopHooksInstalled = YES;
    PFLog(@"MTOP_FM_TABLE_HOOK_INSTALLED class=%@ selectors=requestApiName,requestApiParameter:,_handleResponseResultWithSuccess:data:error:mtopRequestModel:refresh:atLaunch:", NSStringFromClass(cls));
}

static BOOL PFRelevantClassName(NSString *name) {
    NSString *n = name.lowercaseString;
    return [n containsString:@"mtop"] ||
           [n containsString:@"xmodule"] ||
           [n containsString:@"apiprotocol"] ||
           [n containsString:@"apirequest"] ||
           [n containsString:@"apisender"] ||
           [n containsString:@"mtoprequest"] ||
           [n containsString:@"mtopresponse"] ||
           [n containsString:@"signimpl"] ||
           [n containsString:@"networkrequest"] ||
           [n containsString:@"networkresponse"] ||
           [n containsString:@"httprequest"] ||
           [n containsString:@"httpresponse"];
}

static BOOL PFRelevantSelector(NSString *selName) {
    NSString *s = selName.lowercaseString;
    return [s containsString:@"send"] ||
           [s containsString:@"request"] ||
           [s containsString:@"response"] ||
           [s containsString:@"execute"] ||
           [s containsString:@"start"] ||
           [s containsString:@"finish"] ||
           [s containsString:@"callback"] ||
           [s containsString:@"api"] ||
           [s containsString:@"param"] ||
           [s containsString:@"sign"] ||
           [s containsString:@"dispatch"] ||
           [s containsString:@"perform"];
}

static void PFScanMtopClasses(NSString *reason) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        PFLog(@"MTOP_NATIVE_SCAN_EMPTY reason=%@", reason);
        return;
    }

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    NSUInteger matched = 0;
    NSUInteger methodLines = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *rawName = class_getName(cls);
        if (!rawName) continue;
        NSString *name = [NSString stringWithUTF8String:rawName];
        if (!PFRelevantClassName(name)) continue;

        matched++;
        Class superclass = class_getSuperclass(cls);
        PFLog(@"MTOP_NATIVE_CLASS reason=%@ class=%@ superclass=%@",
              reason,
              name,
              superclass ? NSStringFromClass(superclass) : @"(none)");

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSUInteger emitted = 0;
        for (unsigned int j = 0; j < methodCount && emitted < 120; j++) {
            SEL selector = method_getName(methods[j]);
            NSString *selName = NSStringFromSelector(selector);
            if (!PFRelevantSelector(selName)) continue;
            PFLog(@"MTOP_NATIVE_METHOD class=%@ selector=%@ types=%s",
                  name,
                  selName,
                  method_getTypeEncoding(methods[j]) ?: "(unknown)");
            emitted++;
            methodLines++;
        }
        free(methods);
    }

    for (NSString *anchor in @[
        @"NSURLSession", @"NSURLSessionTask", @"NSURLProtocol", @"NSURLConnection"
    ]) {
        Class cls = NSClassFromString(anchor);
        if (!cls) continue;
        PFLog(@"MTOP_NATIVE_ANCHOR class=%@", anchor);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSUInteger emitted = 0;
        for (unsigned int j = 0; j < methodCount && emitted < 80; j++) {
            SEL selector = method_getName(methods[j]);
            NSString *selName = NSStringFromSelector(selector);
            if (!PFRelevantSelector(selName)) continue;
            PFLog(@"MTOP_NATIVE_ANCHOR_METHOD class=%@ selector=%@ types=%s",
                  anchor,
                  selName,
                  method_getTypeEncoding(methods[j]) ?: "(unknown)");
            emitted++;
        }
        free(methods);
    }

    PFInstallFMTablePageMtopHooks();

    PFLog(@"MTOP_NATIVE_SCAN_DONE reason=%@ totalClasses=%d matched=%lu methodLines=%lu",
          reason,
          count,
          (unsigned long)matched,
          (unsigned long)methodLines);
    free(classes);
}

static void PFInstallDelayedScans(void) {
    if (gPFMtopBridgeObserversInstalled) return;
    gPFMtopBridgeObserversInstalled = YES;

    NSArray<NSNumber *> *delays = @[@0.5, @2.0, @5.0, @10.0, @20.0];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PFScanMtopClasses([NSString stringWithFormat:@"delayed_%.1fs", delay.doubleValue]);
        });
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        PFScanMtopClasses(@"application_active");
    }];
}

void PFInstallMtopBridge(void) {
    if (gPFMtopBridgeInstalled) return;
    gPFMtopBridgeInstalled = YES;

    PFLog(@"MTOP_NATIVE_BRIDGE installing read-only FMTablePageMtop observation");
    PFScanMtopClasses(@"startup");
    PFInstallDelayedScans();
    PFLog(@"MTOP_NATIVE_BRIDGE installed; request observation is read-only and does not create, modify, replay, or intercept requests");
}
