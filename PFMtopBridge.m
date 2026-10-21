#import "PFMtopBridge.h"
#import "PFLogger.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL gPFMtopBridgeInstalled = NO;
static BOOL gPFMtopBridgeObserversInstalled = NO;
static BOOL gFMTablePageMtopHooksInstalled = NO;
static BOOL gGenericMtopHooksInstalled = NO;

static id (*PFOriginalFMRequestApiName)(id, SEL);
static id (*PFOriginalFMRequestApiParameter)(id, SEL, BOOL);
static void (*PFOriginalFMHandleResponse)(id, SEL, BOOL, id, id, id, BOOL, BOOL);

static id (*PFOriginalMtopRequestInit)(id, SEL, id, id);
static id (*PFOriginalMtopRequestAddParameter)(id, SEL, id, id);
static id (*PFOriginalMtopRequestAddParameters)(id, SEL, id);
static id (*PFOriginalMtopRequestResponse)(id, SEL);
static id (*PFOriginalApiRequestInit)(id, SEL, id, id);
static id (*PFOriginalApiRequestAddParameter)(id, SEL, id, id);
static id (*PFOriginalApiRequestAddParameters)(id, SEL, id);
static id (*PFOriginalApiRequestResponse)(id, SEL);
static void (*PFOriginalMtopBridgeSend)(id, SEL, id, id, id);
static void (*PFOriginalMtopDelegateSuccess)(id, SEL, id);
static void (*PFOriginalMtopDelegateFailure)(id, SEL, id);

static NSString *PFObjectClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"(nil)";
}

// Deliberately log only structural metadata. Do not dump parameter values,
// cookies, tokens, account identifiers, or response contents.
static NSString *PFSafeShape(id object) {
    if (!object) return @"(nil)";
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSArray *keys = [[(NSDictionary *)object allKeys] sortedArrayUsingComparator:
                         ^NSComparisonResult(id a, id b) {
            return [[a description] compare:[b description]];
        }];
        return [NSString stringWithFormat:@"%@ count=%lu keys=%@",
                PFObjectClassName(object), (unsigned long)keys.count, keys];
    }
    if ([object isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"%@ count=%lu",
                PFObjectClassName(object), (unsigned long)[(NSArray *)object count]];
    }
    return PFObjectClassName(object);
}

static BOOL PFIsApiRequestObject(id object) {
    if (!object) return NO;
    Class apiRequestClass = NSClassFromString(@"ApiRequest");
    return apiRequestClass && [object isKindOfClass:apiRequestClass];
}

static id PFHookedFMRequestApiName(id self, SEL _cmd) {
    id result = PFOriginalFMRequestApiName ? PFOriginalFMRequestApiName(self, _cmd) : nil;
    PFLog(@"MTOP_OBSERVED_FM_TABLE_API class=%@ api=%@",
          NSStringFromClass([self class]), result ?: @"(nil)");
    return result;
}

static id PFHookedFMRequestApiParameter(id self, SEL _cmd, BOOL isPrefetch) {
    id result = PFOriginalFMRequestApiParameter ? PFOriginalFMRequestApiParameter(self, _cmd, isPrefetch) : nil;
    PFLog(@"MTOP_OBSERVED_FM_TABLE_PARAM class=%@ prefetch=%d shape=%@",
          NSStringFromClass([self class]), isPrefetch, PFSafeShape(result));
    return result;
}

static void PFHookedFMHandleResponse(id self, SEL _cmd, BOOL success, id data, id error,
                                     id requestModel, BOOL refresh, BOOL atLaunch) {
    PFLog(@"MTOP_OBSERVED_FM_TABLE_RESPONSE class=%@ success=%d dataShape=%@ errorClass=%@ requestClass=%@ refresh=%d atLaunch=%d",
          NSStringFromClass([self class]), success, PFSafeShape(data),
          PFObjectClassName(error), PFObjectClassName(requestModel), refresh, atLaunch);
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
    PFLog(@"MTOP_FM_TABLE_HOOK_INSTALLED class=%@ selectors=requestApiName,requestApiParameter:,_handleResponseResultWithSuccess:data:error:mtopRequestModel:refresh:atLaunch:",
          NSStringFromClass(cls));
}

static id PFHookedMtopRequestInit(id self, SEL _cmd, id api, id version) {
    id (*original)(id, SEL, id, id) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestInit : PFOriginalMtopRequestInit;
    id result = original ? original(self, _cmd, api, version) : self;
    PFLog(@"MTOP_OBSERVED_REQUEST_INIT class=%@ api=%@ version=%@",
          PFObjectClassName(result ?: self), api ?: @"(nil)", version ?: @"(nil)");
    return result;
}

static id PFHookedMtopRequestAddParameter(id self, SEL _cmd, id value, id key) {
    id (*original)(id, SEL, id, id) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestAddParameter : PFOriginalMtopRequestAddParameter;
    PFLog(@"MTOP_OBSERVED_PARAMETER_KEY class=%@ key=%@ valueClass=%@",
          PFObjectClassName(self), [key isKindOfClass:[NSString class]] ? key : @"(non-string-key)",
          PFObjectClassName(value));
    return original ? original(self, _cmd, value, key) : self;
}

static id PFHookedMtopRequestAddParameters(id self, SEL _cmd, id params) {
    id (*original)(id, SEL, id) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestAddParameters : PFOriginalMtopRequestAddParameters;
    PFLog(@"MTOP_OBSERVED_PARAMETER_KEYS class=%@ shape=%@",
          PFObjectClassName(self), PFSafeShape(params));
    return original ? original(self, _cmd, params) : self;
}

static id PFHookedMtopRequestResponse(id self, SEL _cmd) {
    id (*original)(id, SEL) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestResponse : PFOriginalMtopRequestResponse;
    id result = original ? original(self, _cmd) : nil;
    PFLog(@"MTOP_OBSERVED_REQUEST_RESPONSE class=%@ responseShape=%@",
          PFObjectClassName(self), PFSafeShape(result));
    return result;
}

static void PFHookedMtopBridgeSend(id self, SEL _cmd, id request, id callback, id ext) {
    PFLog(@"MTOP_OBSERVED_BRIDGE_SEND bridgeClass=%@ requestShape=%@ callbackClass=%@ extShape=%@",
          PFObjectClassName(self), PFSafeShape(request), PFObjectClassName(callback), PFSafeShape(ext));
    if (PFOriginalMtopBridgeSend) PFOriginalMtopBridgeSend(self, _cmd, request, callback, ext);
}

static void PFHookedMtopDelegateSuccess(id self, SEL _cmd, id response) {
    PFLog(@"MTOP_OBSERVED_DELEGATE_SUCCESS delegateClass=%@ responseShape=%@",
          PFObjectClassName(self), PFSafeShape(response));
    if (PFOriginalMtopDelegateSuccess) PFOriginalMtopDelegateSuccess(self, _cmd, response);
}

static void PFHookedMtopDelegateFailure(id self, SEL _cmd, id error) {
    PFLog(@"MTOP_OBSERVED_DELEGATE_FAILURE delegateClass=%@ errorClass=%@",
          PFObjectClassName(self), PFObjectClassName(error));
    if (PFOriginalMtopDelegateFailure) PFOriginalMtopDelegateFailure(self, _cmd, error);
}

static BOOL PFReplaceMethod(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    if (!cls || !selector || !replacement || !originalOut) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *originalOut = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return YES;
}

static void PFInstallGenericMtopObservationHooks(void) {
    if (gGenericMtopHooksInstalled) return;

    BOOL installedAny = NO;
    Class mtopRequestClass = NSClassFromString(@"MtopApiRequest");
    if (mtopRequestClass) {
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(initWithApiName:version:),
                                        (IMP)PFHookedMtopRequestInit, (IMP *)&PFOriginalMtopRequestInit);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(addParameter:forKey:),
                                        (IMP)PFHookedMtopRequestAddParameter, (IMP *)&PFOriginalMtopRequestAddParameter);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(addParameters:),
                                        (IMP)PFHookedMtopRequestAddParameters, (IMP *)&PFOriginalMtopRequestAddParameters);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(response),
                                        (IMP)PFHookedMtopRequestResponse, (IMP *)&PFOriginalMtopRequestResponse);
    }

    Class apiRequestClass = NSClassFromString(@"ApiRequest");
    if (apiRequestClass) {
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(initWithApiName:version:),
                                        (IMP)PFHookedMtopRequestInit, (IMP *)&PFOriginalApiRequestInit);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(addParameter:forKey:),
                                        (IMP)PFHookedMtopRequestAddParameter, (IMP *)&PFOriginalApiRequestAddParameter);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(addParameters:),
                                        (IMP)PFHookedMtopRequestAddParameters, (IMP *)&PFOriginalApiRequestAddParameters);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(response),
                                        (IMP)PFHookedMtopRequestResponse, (IMP *)&PFOriginalApiRequestResponse);
    }

    Class bridgeClass = NSClassFromString(@"MtopBridgePlugin");
    if (bridgeClass) {
        installedAny |= PFReplaceMethod(bridgeClass, @selector(sendMtopRequest:callBack:ext:),
                                        (IMP)PFHookedMtopBridgeSend, (IMP *)&PFOriginalMtopBridgeSend);
    }

    Class delegateClass = NSClassFromString(@"MtopApiRequestDelegateImpl");
    if (delegateClass) {
        installedAny |= PFReplaceMethod(delegateClass, @selector(requestSuccess:),
                                        (IMP)PFHookedMtopDelegateSuccess, (IMP *)&PFOriginalMtopDelegateSuccess);
        installedAny |= PFReplaceMethod(delegateClass, @selector(requestFailed:),
                                        (IMP)PFHookedMtopDelegateFailure, (IMP *)&PFOriginalMtopDelegateFailure);
    }

    if (installedAny) {
        gGenericMtopHooksInstalled = YES;
        PFLog(@"MTOP_GENERIC_OBSERVATION_HOOKS_INSTALLED MtopApiRequest=%d ApiRequest=%d MtopBridgePlugin=%d MtopApiRequestDelegateImpl=%d",
              mtopRequestClass != Nil, apiRequestClass != Nil, bridgeClass != Nil, delegateClass != Nil);
    } else {
        PFLog(@"MTOP_GENERIC_OBSERVATION_HOOKS_WAIT MtopApiRequest=%d ApiRequest=%d MtopBridgePlugin=%d MtopApiRequestDelegateImpl=%d",
              mtopRequestClass != Nil, apiRequestClass != Nil, bridgeClass != Nil, delegateClass != Nil);
    }
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
              reason, name, superclass ? NSStringFromClass(superclass) : @"(none)");

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSUInteger emitted = 0;
        for (unsigned int j = 0; j < methodCount && emitted < 120; j++) {
            SEL selector = method_getName(methods[j]);
            NSString *selName = NSStringFromSelector(selector);
            if (!PFRelevantSelector(selName)) continue;
            PFLog(@"MTOP_NATIVE_METHOD class=%@ selector=%@ types=%s",
                  name, selName, method_getTypeEncoding(methods[j]) ?: "(unknown)");
            emitted++;
            methodLines++;
        }
        free(methods);
    }

    for (NSString *anchor in @[@"NSURLSession", @"NSURLSessionTask", @"NSURLProtocol", @"NSURLConnection"]) {
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
                  anchor, selName, method_getTypeEncoding(methods[j]) ?: "(unknown)");
            emitted++;
        }
        free(methods);
    }

    PFInstallFMTablePageMtopHooks();
    PFInstallGenericMtopObservationHooks();

    PFLog(@"MTOP_NATIVE_SCAN_DONE reason=%@ totalClasses=%d matched=%lu methodLines=%lu",
          reason, count, (unsigned long)matched, (unsigned long)methodLines);
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

    PFLog(@"MTOP_NATIVE_BRIDGE installing read-only request-construction and response observation");
    PFScanMtopClasses(@"startup");
    PFInstallDelayedScans();
    PFLog(@"MTOP_NATIVE_BRIDGE installed; logs contain structural metadata only; no requests are created, modified, or replayed");
}
