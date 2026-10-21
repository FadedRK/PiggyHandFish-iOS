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
static id (*PFOriginalMtopRequestInitWithBiz)(id, SEL, id, id, id, id);
static id (*PFOriginalMtopRequestAddParameter)(id, SEL, id, id);
static id (*PFOriginalMtopRequestAddHttpParameter)(id, SEL, id, id);
static id (*PFOriginalMtopRequestAddHttpParameterNoneURLEncoding)(id, SEL, id, id);
static id (*PFOriginalMtopRequestAddHttpParameters)(id, SEL, id);
static id (*PFOriginalMtopRequestAddParameters)(id, SEL, id);
static id (*PFOriginalMtopRequestResponse)(id, SEL);
static void (*PFOriginalMtopRequestGenerate)(id, SEL);
static id (*PFOriginalApiRequestInit)(id, SEL, id, id);
static id (*PFOriginalApiRequestAddParameter)(id, SEL, id, id);
static id (*PFOriginalApiRequestAddHttpParameter)(id, SEL, id, id);
static id (*PFOriginalApiRequestAddHttpParameters)(id, SEL, id);
static id (*PFOriginalApiRequestAddParameters)(id, SEL, id);
static id (*PFOriginalApiRequestResponse)(id, SEL);
static void (*PFOriginalApiRequestGenerate)(id, SEL);
static void (*PFOriginalMtopBridgeSend)(id, SEL, id, id, id);
static void (*PFOriginalMtopBridgePending)(id, SEL, id, id, id);
static void (*PFOriginalMtopDelegateSuccess)(id, SEL, id);
static void (*PFOriginalMtopDelegateFailure)(id, SEL, id);
static void (*PFOriginalMtopDelegateDidLoadCache)(id, SEL, id, id, id);
static char PFRequestStartTimeKey;
static char PFRequestAPIKey;
static char PFRequestVersionKey;

// Privacy-safe request/response logging: retain field names and value shapes,
// but never dump arbitrary parameter values, cookies, tokens, signatures, or bodies.
static NSString *PFObjectClassName(id object) {
    return object ? NSStringFromClass([object class]) : @"(nil)";
}

static NSString *PFSafeIdentifier(id object) {
    if ([object isKindOfClass:[NSString class]]) {
        NSString *value = (NSString *)object;
        if (value.length <= 120) {
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                                       @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:-"];
            if ([value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound) return value;
        }
        return [NSString stringWithFormat:@"<NSString len=%lu>", (unsigned long)value.length];
    }
    if ([object isKindOfClass:[NSNumber class]]) return PFObjectClassName(object);
    return PFObjectClassName(object);
}

static NSString *PFSafeShapeAtDepth(id object, NSUInteger depth) {
    if (!object) return @"(nil)";
    if (depth > 2) return PFObjectClassName(object);

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        NSArray *keys = [[dictionary allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a description] compare:[b description]];
        }];
        NSMutableArray *fields = [NSMutableArray array];
        NSUInteger limit = MIN(keys.count, 24);
        for (NSUInteger i = 0; i < limit; i++) {
            id key = keys[i];
            NSString *keyName = [key isKindOfClass:[NSString class]]
                ? ([(NSString *)key length] <= 100 ? (NSString *)key : @"<long-key>")
                : [NSString stringWithFormat:@"<%@-key>", PFObjectClassName(key)];
            id value = dictionary[key];
            [fields addObject:[NSString stringWithFormat:@"%@:%@", keyName, PFSafeShapeAtDepth(value, depth + 1)]];
        }
        if (keys.count > limit) [fields addObject:[NSString stringWithFormat:@"...(+%lu keys)", (unsigned long)(keys.count - limit)]];
        return [NSString stringWithFormat:@"%@ count=%lu fields={%@}",
                PFObjectClassName(object), (unsigned long)keys.count, [fields componentsJoinedByString:@","]];
    }

    if ([object isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)object;
        NSMutableArray *items = [NSMutableArray array];
        NSUInteger limit = MIN(array.count, 5);
        for (NSUInteger i = 0; i < limit; i++) {
            [items addObject:PFSafeShapeAtDepth(array[i], depth + 1)];
        }
        if (array.count > limit) [items addObject:@"..."];
        return [NSString stringWithFormat:@"%@ count=%lu items=[%@]",
                PFObjectClassName(object), (unsigned long)array.count, [items componentsJoinedByString:@","]];
    }

    if ([object isKindOfClass:[NSString class]]) {
        return [NSString stringWithFormat:@"%@ len=%lu", PFObjectClassName(object), (unsigned long)[(NSString *)object length]];
    }
    if ([object isKindOfClass:[NSData class]]) {
        return [NSString stringWithFormat:@"%@ len=%lu", PFObjectClassName(object), (unsigned long)[(NSData *)object length]];
    }
    if ([object isKindOfClass:[NSError class]]) {
        return [NSString stringWithFormat:@"%@ code=%ld userInfoShape=%@",
                PFObjectClassName(object), (long)[(NSError *)object code],
                PFSafeShapeAtDepth([(NSError *)object userInfo], depth + 1)];
    }
    return PFObjectClassName(object);
}

static NSString *PFSafeShape(id object) {
    return PFSafeShapeAtDepth(object, 0);
}

static BOOL PFSafeCodeString(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 80) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:-."];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static void PFCollectSafeResultCodes(id object, NSString *prefix, NSUInteger depth, NSMutableArray<NSString *> *output) {
    if (!object || depth > 3 || output.count >= 16) return;
    NSSet *safeKeys = [NSSet setWithArray:@[@"ret", @"code", @"status", @"success", @"errorcode", @"errcode", @"errno", @"msgcode", @"resultcode", @"state", @"taskstatus", @"taskstate", @"benefitstatus", @"rewardstatus", @"claimed", @"isclaimed", @"completed", @"iscompleted", @"finished", @"isfinished", @"retcode", @"statuscode", @"resultstatus", @"successflag"]];
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        for (id rawKey in dictionary) {
            if (output.count >= 16) break;
            if (![rawKey isKindOfClass:[NSString class]]) continue;
            NSString *key = (NSString *)rawKey;
            id value = dictionary[rawKey];
            NSString *path = prefix.length ? [NSString stringWithFormat:@"%@.%@", prefix, key] : key;
            NSString *lower = key.lowercaseString;
            if ([safeKeys containsObject:lower]) {
                if ([value isKindOfClass:[NSNumber class]]) {
                    [output addObject:[NSString stringWithFormat:@"%@=%@", path, value]];
                } else if ([value isKindOfClass:[NSString class]] && PFSafeCodeString(value)) {
                    [output addObject:[NSString stringWithFormat:@"%@=%@", path, value]];
                } else if (value == [NSNull null]) {
                    [output addObject:[NSString stringWithFormat:@"%@=(null)", path]];
                }
            }
            if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
                PFCollectSafeResultCodes(value, path, depth + 1, output);
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)object;
        NSUInteger limit = MIN(array.count, 8);
        for (NSUInteger i = 0; i < limit && output.count < 16; i++) {
            PFCollectSafeResultCodes(array[i], [NSString stringWithFormat:@"%@[%lu]", prefix, (unsigned long)i], depth + 1, output);
        }
    }
}

static NSString *PFSafeResultCodes(id object) {
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    PFCollectSafeResultCodes(object, @"", 0, codes);
    return codes.count ? [codes componentsJoinedByString:@","] : @"(no-safe-status-fields)";
}

static NSString *PFResponseSummary(id object) {
    return [NSString stringWithFormat:@"shape={%@} safeCodes={%@}", PFSafeShape(object), PFSafeResultCodes(object)];
}

static NSString *PFErrorSummary(id error) {
    if (!error) return @"(nil)";
    if ([error isKindOfClass:[NSError class]]) {
        NSError *e = (NSError *)error;
        return [NSString stringWithFormat:@"%@ code=%ld userInfoShape={%@}",
                PFObjectClassName(error), (long)e.code, PFSafeShape(e.userInfo)];
    }
    return PFSafeShape(error);
}

static CFTimeInterval PFElapsedSinceRequestInit(id object) {
    NSNumber *start = objc_getAssociatedObject(object, &PFRequestStartTimeKey);
    return start ? MAX(0, CFAbsoluteTimeGetCurrent() - start.doubleValue) * 1000.0 : -1;
}

// Invoke only object-returning getters, after checking the real runtime method encoding.
static id PFInvokeObservedObjectGetter(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    Method method = class_getInstanceMethod([object class], selector);
    if (!method) return nil;
    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != '@') return nil;
    IMP implementation = method_getImplementation(method);
    return implementation ? ((id (*)(id, SEL))implementation)(object, selector) : nil;
}

static NSString *PFRequestTraceMetadata(id request) {
    if (!request) return @"request=(nil)";
    id associatedAPI = objc_getAssociatedObject(request, &PFRequestAPIKey);
    id associatedVersion = objc_getAssociatedObject(request, &PFRequestVersionKey);
    id api = [associatedAPI isKindOfClass:[NSString class]] ? associatedAPI
        : PFInvokeObservedObjectGetter(request, @selector(getApiName));
    id version = [associatedVersion isKindOfClass:[NSString class]] ? associatedVersion
        : PFInvokeObservedObjectGetter(request, @selector(getApiVersion));
    return [NSString stringWithFormat:@"request=%p requestClass=%@ api=%@ version=%@ elapsedSinceInitMs=%.1f",
            request, PFObjectClassName(request), PFSafeIdentifier(api), PFSafeIdentifier(version),
            PFElapsedSinceRequestInit(request)];
}

static NSString *PFResponseTraceMetadata(id response) {
    if (!response) return @"response=(nil)";
    if ([response isKindOfClass:[NSDictionary class]] || [response isKindOfClass:[NSArray class]]) {
        return PFResponseSummary(response);
    }
    id apiVersion = PFInvokeObservedObjectGetter(response, @selector(apiVersion));
    id apiMethod = PFInvokeObservedObjectGetter(response, @selector(apiMethod));
    id nestedRequest = PFInvokeObservedObjectGetter(response, @selector(request));
    NSString *requestMeta = nestedRequest ? PFRequestTraceMetadata(nestedRequest) : @"request=(not-exposed)";
    return [NSString stringWithFormat:@"class=%@ apiMethod=%@ apiVersion=%@ %@ shape={%@} safeCodes={%@}",
            PFObjectClassName(response), PFSafeIdentifier(apiMethod), PFSafeIdentifier(apiVersion),
            requestMeta, PFSafeShape(response), PFSafeResultCodes(response)];
}

static NSString *PFDelegateRequestTrace(id delegate) {
    id request = PFInvokeObservedObjectGetter(delegate, @selector(request));
    return request ? PFRequestTraceMetadata(request) : @"delegateRequest=(not-exposed)";
}

static BOOL PFIsApiRequestObject(id object) {
    if (!object) return NO;
    Class apiRequestClass = NSClassFromString(@"ApiRequest");
    return apiRequestClass && [object isKindOfClass:apiRequestClass];
}

static id PFHookedFMRequestApiName(id self, SEL _cmd) {
    id result = PFOriginalFMRequestApiName ? PFOriginalFMRequestApiName(self, _cmd) : nil;
    PFLog(@"MTOP_EVENT stage=fm_table_api class=%@ api=%@", NSStringFromClass([self class]), PFSafeIdentifier(result));
    return result;
}

static id PFHookedFMRequestApiParameter(id self, SEL _cmd, BOOL isPrefetch) {
    id result = PFOriginalFMRequestApiParameter ? PFOriginalFMRequestApiParameter(self, _cmd, isPrefetch) : nil;
    PFLog(@"MTOP_EVENT stage=fm_table_parameters class=%@ prefetch=%d %@", NSStringFromClass([self class]), isPrefetch, PFResponseSummary(result));
    return result;
}

static void PFHookedFMHandleResponse(id self, SEL _cmd, BOOL success, id data, id error,
                                     id requestModel, BOOL refresh, BOOL atLaunch) {
    PFLog(@"MTOP_EVENT stage=fm_table_response class=%@ success=%d response={%@} error={%@} requestClass=%@ request=%p refresh=%d atLaunch=%d",
          NSStringFromClass([self class]), success, PFResponseSummary(data), PFErrorSummary(error),
          PFObjectClassName(requestModel), requestModel, refresh, atLaunch);
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
    id tracked = result ?: self;
    objc_setAssociatedObject(tracked, &PFRequestStartTimeKey, @(CFAbsoluteTimeGetCurrent()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([api isKindOfClass:[NSString class]]) objc_setAssociatedObject(tracked, &PFRequestAPIKey, api, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([version isKindOfClass:[NSString class]]) objc_setAssociatedObject(tracked, &PFRequestVersionKey, version, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PFLog(@"MTOP_EVENT stage=request_init class=%@ request=%p api=%@ version=%@ thread=%p",
          PFObjectClassName(tracked), tracked, PFSafeIdentifier(api), PFSafeIdentifier(version), [NSThread currentThread]);
    return result;
}

static id PFHookedMtopRequestInitWithBiz(id self, SEL _cmd, id api, id version, id bizId, id bizTopic) {
    id result = PFOriginalMtopRequestInitWithBiz ? PFOriginalMtopRequestInitWithBiz(self, _cmd, api, version, bizId, bizTopic) : self;
    id tracked = result ?: self;
    objc_setAssociatedObject(tracked, &PFRequestStartTimeKey, @(CFAbsoluteTimeGetCurrent()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([api isKindOfClass:[NSString class]]) objc_setAssociatedObject(tracked, &PFRequestAPIKey, api, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([version isKindOfClass:[NSString class]]) objc_setAssociatedObject(tracked, &PFRequestVersionKey, version, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PFLog(@"MTOP_EVENT stage=request_init_biz class=%@ request=%p api=%@ version=%@ bizIdShape=%@ bizTopicShape=%@ thread=%p",
          PFObjectClassName(tracked), tracked, PFSafeIdentifier(api), PFSafeIdentifier(version),
          PFSafeShape(bizId), PFSafeShape(bizTopic), [NSThread currentThread]);
    return result;
}

static id PFHookedMtopRequestAddParameter(id self, SEL _cmd, id value, id key) {
    id (*original)(id, SEL, id, id) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestAddParameter : PFOriginalMtopRequestAddParameter;
    PFLog(@"MTOP_EVENT stage=request_parameter request=%p class=%@ source=addParameter key=%@ valueShape=%@ elapsedMs=%.1f",
          self, PFObjectClassName(self), PFSafeIdentifier(key), PFSafeShape(value), PFElapsedSinceRequestInit(self));
    return original ? original(self, _cmd, value, key) : self;
}

static id PFHookedMtopRequestAddHttpParameter(id self, SEL _cmd, id value, id key) {
    id (*original)(id, SEL, id, id) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestAddHttpParameter : PFOriginalMtopRequestAddHttpParameter;
    PFLog(@"MTOP_EVENT stage=request_parameter request=%p class=%@ source=addHttpParameter key=%@ valueShape=%@ elapsedMs=%.1f",
          self, PFObjectClassName(self), PFSafeIdentifier(key), PFSafeShape(value), PFElapsedSinceRequestInit(self));
    return original ? original(self, _cmd, value, key) : self;
}

static id PFHookedMtopRequestAddHttpParameterNoneURLEncoding(id self, SEL _cmd, id value, id key) {
    PFLog(@"MTOP_EVENT stage=request_parameter request=%p class=%@ source=addHttpParameterNoneURLEncoding key=%@ valueShape=%@ elapsedMs=%.1f",
          self, PFObjectClassName(self), PFSafeIdentifier(key), PFSafeShape(value), PFElapsedSinceRequestInit(self));
    return PFOriginalMtopRequestAddHttpParameterNoneURLEncoding
        ? PFOriginalMtopRequestAddHttpParameterNoneURLEncoding(self, _cmd, value, key) : self;
}

static id PFHookedMtopRequestAddHttpParameters(id self, SEL _cmd, id params) {
    id (*original)(id, SEL, id) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestAddHttpParameters : PFOriginalMtopRequestAddHttpParameters;
    PFLog(@"MTOP_EVENT stage=request_parameter_batch request=%p class=%@ source=addHttpParameters params={%@} elapsedMs=%.1f",
          self, PFObjectClassName(self), PFSafeShape(params), PFElapsedSinceRequestInit(self));
    return original ? original(self, _cmd, params) : self;
}

static id PFHookedMtopRequestAddParameters(id self, SEL _cmd, id params) {
    id (*original)(id, SEL, id) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestAddParameters : PFOriginalMtopRequestAddParameters;
    PFLog(@"MTOP_EVENT stage=request_parameter_batch request=%p class=%@ source=addParameters params={%@} elapsedMs=%.1f",
          self, PFObjectClassName(self), PFSafeShape(params), PFElapsedSinceRequestInit(self));
    return original ? original(self, _cmd, params) : self;
}

static void PFHookedMtopRequestGenerate(id self, SEL _cmd) {
    BOOL isAPI = PFIsApiRequestObject(self);
    void (*original)(id, SEL) = isAPI ? PFOriginalApiRequestGenerate : PFOriginalMtopRequestGenerate;
    CFTimeInterval start = CFAbsoluteTimeGetCurrent();
    PFLog(@"MTOP_EVENT stage=request_generate_begin request=%p class=%@ elapsedSinceInitMs=%.1f",
          self, PFObjectClassName(self), PFElapsedSinceRequestInit(self));
    if (original) original(self, _cmd);
    PFLog(@"MTOP_EVENT stage=request_generate_end request=%p class=%@ generateMs=%.1f totalSinceInitMs=%.1f",
          self, PFObjectClassName(self), (CFAbsoluteTimeGetCurrent() - start) * 1000.0, PFElapsedSinceRequestInit(self));
}

static id PFHookedMtopRequestResponse(id self, SEL _cmd) {
    id (*original)(id, SEL) = PFIsApiRequestObject(self)
        ? PFOriginalApiRequestResponse : PFOriginalMtopRequestResponse;
    id result = original ? original(self, _cmd) : nil;
    PFLog(@"MTOP_EVENT stage=request_response %@ response={%@}",
          PFRequestTraceMetadata(self), PFResponseTraceMetadata(result));
    return result;
}

static void PFHookedMtopBridgeSend(id self, SEL _cmd, id request, id callback, id ext) {
    PFLog(@"MTOP_EVENT stage=bridge_send bridge=%p bridgeClass=%@ request=%p requestClass=%@ callbackClass=%@ ext={%@}",
          self, PFObjectClassName(self), request, PFObjectClassName(request), PFObjectClassName(callback), PFSafeShape(ext));
    if (PFOriginalMtopBridgeSend) PFOriginalMtopBridgeSend(self, _cmd, request, callback, ext);
}

static void PFHookedMtopBridgePending(id self, SEL _cmd, id pending, id request, id delegate) {
    PFLog(@"MTOP_EVENT stage=bridge_pending bridge=%p bridgeClass=%@ pendingShape=%@ request=%p requestClass=%@ delegate=%p delegateClass=%@",
          self, PFObjectClassName(self), PFSafeShape(pending), request, PFObjectClassName(request), delegate, PFObjectClassName(delegate));
    if (PFOriginalMtopBridgePending) PFOriginalMtopBridgePending(self, _cmd, pending, request, delegate);
}

static void PFHookedMtopDelegateSuccess(id self, SEL _cmd, id response) {
    PFLog(@"MTOP_EVENT stage=delegate_success delegate=%p delegateClass=%@ requestTrace={%@} responseTrace={%@}",
          self, PFObjectClassName(self), PFDelegateRequestTrace(self), PFResponseTraceMetadata(response));
    if (PFOriginalMtopDelegateSuccess) PFOriginalMtopDelegateSuccess(self, _cmd, response);
}

static void PFHookedMtopDelegateFailure(id self, SEL _cmd, id error) {
    PFLog(@"MTOP_EVENT stage=delegate_failure delegate=%p delegateClass=%@ requestTrace={%@} error={%@}",
          self, PFObjectClassName(self), PFDelegateRequestTrace(self), PFErrorSummary(error));
    if (PFOriginalMtopDelegateFailure) PFOriginalMtopDelegateFailure(self, _cmd, error);
}

static void PFHookedMtopDelegateDidLoadCache(id self, SEL _cmd, id didLoadCache, id responseHeader, id body) {
    PFLog(@"MTOP_EVENT stage=delegate_cache delegate=%p delegateClass=%@ requestTrace={%@} cacheFlagShape=%@ headerShape={%@} bodyTrace={%@}",
          self, PFObjectClassName(self), PFDelegateRequestTrace(self), PFSafeShape(didLoadCache),
          PFSafeShape(responseHeader), PFResponseTraceMetadata(body));
    if (PFOriginalMtopDelegateDidLoadCache) PFOriginalMtopDelegateDidLoadCache(self, _cmd, didLoadCache, responseHeader, body);
}

static BOOL PFReplaceMethod(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    if (!cls || !selector || !replacement || !originalOut) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *originalOut = method_getImplementation(method);
    method_setImplementation(method, replacement);
    PFLog(@"MTOP_HOOK_INSTALLED class=%@ selector=%@ types=%s",
          NSStringFromClass(cls), NSStringFromSelector(selector),
          method_getTypeEncoding(method) ?: "(unknown)");
    return YES;
}

static void PFInstallGenericMtopObservationHooks(void) {
    if (gGenericMtopHooksInstalled) return;

    BOOL installedAny = NO;
    Class mtopRequestClass = NSClassFromString(@"MtopApiRequest");
    if (mtopRequestClass) {
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(initWithApiName:version:),
                                        (IMP)PFHookedMtopRequestInit, (IMP *)&PFOriginalMtopRequestInit);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(initWithApiName:version:bizId:bizTopic:),
                                        (IMP)PFHookedMtopRequestInitWithBiz, (IMP *)&PFOriginalMtopRequestInitWithBiz);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(addParameter:forKey:),
                                        (IMP)PFHookedMtopRequestAddParameter, (IMP *)&PFOriginalMtopRequestAddParameter);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(addHttpParameter:forKey:),
                                        (IMP)PFHookedMtopRequestAddHttpParameter, (IMP *)&PFOriginalMtopRequestAddHttpParameter);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(addHttpParameterNoneURLEncoding:forKey:),
                                        (IMP)PFHookedMtopRequestAddHttpParameterNoneURLEncoding, (IMP *)&PFOriginalMtopRequestAddHttpParameterNoneURLEncoding);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(addHttpParameters:),
                                        (IMP)PFHookedMtopRequestAddHttpParameters, (IMP *)&PFOriginalMtopRequestAddHttpParameters);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(addParameters:),
                                        (IMP)PFHookedMtopRequestAddParameters, (IMP *)&PFOriginalMtopRequestAddParameters);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(generateMtopRequest),
                                        (IMP)PFHookedMtopRequestGenerate, (IMP *)&PFOriginalMtopRequestGenerate);
        installedAny |= PFReplaceMethod(mtopRequestClass, @selector(response),
                                        (IMP)PFHookedMtopRequestResponse, (IMP *)&PFOriginalMtopRequestResponse);
    }

    Class apiRequestClass = NSClassFromString(@"ApiRequest");
    if (apiRequestClass) {
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(initWithApiName:version:),
                                        (IMP)PFHookedMtopRequestInit, (IMP *)&PFOriginalApiRequestInit);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(addParameter:forKey:),
                                        (IMP)PFHookedMtopRequestAddParameter, (IMP *)&PFOriginalApiRequestAddParameter);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(addHttpParameter:forKey:),
                                        (IMP)PFHookedMtopRequestAddHttpParameter, (IMP *)&PFOriginalApiRequestAddHttpParameter);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(addHttpParameters:),
                                        (IMP)PFHookedMtopRequestAddHttpParameters, (IMP *)&PFOriginalApiRequestAddHttpParameters);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(addParameters:),
                                        (IMP)PFHookedMtopRequestAddParameters, (IMP *)&PFOriginalApiRequestAddParameters);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(generateMtopRequest),
                                        (IMP)PFHookedMtopRequestGenerate, (IMP *)&PFOriginalApiRequestGenerate);
        installedAny |= PFReplaceMethod(apiRequestClass, @selector(response),
                                        (IMP)PFHookedMtopRequestResponse, (IMP *)&PFOriginalApiRequestResponse);
    }

    Class bridgeClass = NSClassFromString(@"MtopBridgePlugin");
    if (bridgeClass) {
        installedAny |= PFReplaceMethod(bridgeClass, @selector(sendMtopRequest:callBack:ext:),
                                        (IMP)PFHookedMtopBridgeSend, (IMP *)&PFOriginalMtopBridgeSend);
        installedAny |= PFReplaceMethod(bridgeClass, @selector(pending:request:delegate:),
                                        (IMP)PFHookedMtopBridgePending, (IMP *)&PFOriginalMtopBridgePending);
    }

    Class delegateClass = NSClassFromString(@"MtopApiRequestDelegateImpl");
    if (delegateClass) {
        installedAny |= PFReplaceMethod(delegateClass, @selector(requestSuccess:),
                                        (IMP)PFHookedMtopDelegateSuccess, (IMP *)&PFOriginalMtopDelegateSuccess);
        installedAny |= PFReplaceMethod(delegateClass, @selector(requestFailed:),
                                        (IMP)PFHookedMtopDelegateFailure, (IMP *)&PFOriginalMtopDelegateFailure);
        installedAny |= PFReplaceMethod(delegateClass, @selector(didLoadCache:responseHeader:body:),
                                        (IMP)PFHookedMtopDelegateDidLoadCache, (IMP *)&PFOriginalMtopDelegateDidLoadCache);
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
    return [n isEqualToString:@"tbsdkserver"] ||
           [n containsString:@"mtop"] ||
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
            BOOL responseSDKClass = [name isEqualToString:@"TBSDKServer"] || [name isEqualToString:@"TBSDKMTOPServer"];
            NSString *lowerSelector = selName.lowercaseString;
            BOOL responseRelevant = responseSDKClass &&
                ([lowerSelector containsString:@"status"] || [lowerSelector containsString:@"ret"] ||
                 [lowerSelector containsString:@"code"] || [lowerSelector containsString:@"error"] ||
                 [lowerSelector containsString:@"result"] || [lowerSelector containsString:@"body"] ||
                 [lowerSelector containsString:@"data"] || [lowerSelector containsString:@"json"] ||
                 [lowerSelector containsString:@"success"] || [lowerSelector containsString:@"header"]);
            if (!PFRelevantSelector(selName) && !responseRelevant) continue;
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
