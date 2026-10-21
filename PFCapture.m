#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <stdarg.h>

static NSInteger const PFCaptureButtonTag = 0x50464331;

static IMP gRouterOpen3Original = NULL;
static IMP gRouterOpen4Original = NULL;
static IMP gRouterSafeOpen1Original = NULL;
static IMP gRouterSafeOpen4Original = NULL;
static IMP gRouterHandleOriginal = NULL;
static IMP gRouterCallHandlerOriginal = NULL;
static IMP gRouterOpenViewControllerOriginal = NULL;
static IMP gRouterCreateRouterObjectOriginal = NULL;
static IMP gRouterPreProcessURLOriginal = NULL;
static IMP gRouterUtilOpenUrlOriginal = NULL;
static IMP gFlutterRouterPushRouteOriginal = NULL;
static IMP gFlutterRouterPopRouteOriginal = NULL;
static IMP gFlutterRouterRemoveRouteOriginal = NULL;
static IMP gNavigationPushOriginal = NULL;
static IMP gViewControllerPresentOriginal = NULL;
static IMP gUIApplicationOpenURLOriginal = NULL;
static IMP gUIApplicationOpenURLLegacyOriginal = NULL;
static IMP gMethodChannelInitOriginal = NULL;
static IMP gBasicChannelInitOriginal = NULL;
static IMP gMethodChannelInvokeOriginal = NULL;
static IMP gBasicChannelSendOriginal = NULL;
static IMP gBasicChannelSendReplyOriginal = NULL;
static IMP gBasicChannelSetHandlerOriginal = NULL;
static IMP gMethodChannelSetHandlerOriginal = NULL;

static NSMutableSet<NSString *> *gPFCaptureInstalledHooks;
static NSObject *gPFCaptureLogLock;
static id gPFCaptureActiveObserver;
static UIButton *gPFCaptureButton;
static NSUInteger gPFCaptureRetryCount = 0;
static BOOL gPFCaptureInventoryWritten = NO;
static BOOL gPFCaptureRetryScheduled = NO;

@class PFCaptureButtonTarget;
static PFCaptureButtonTarget *PFCaptureTarget(void);

static NSObject *PFCaptureLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gPFCaptureLogLock = [NSObject new];
    });
    return gPFCaptureLogLock;
}

static NSString *PFCaptureLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"piggyhandfish-capture.log"];
}

static void PFCaptureLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"%@ [PiggyHandFish-Capture] %@\n",
                      [NSDate date], message ?: @"(empty log line)"];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    @synchronized (PFCaptureLock()) {
        NSString *path = PFCaptureLogPath();
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *exception) {
        } @finally {
            [handle closeFile];
        }
    }
}

static BOOL PFCaptureIsSensitiveKey(NSString *key) {
    NSString *lower = key.lowercaseString;
    NSArray<NSString *> *blocked = @[@"token", @"cookie", @"password", @"passwd",
                                     @"authorization", @"session", @"secret",
                                     @"mobile", @"phone", @"account", @"userId"];
    for (NSString *item in blocked) {
        if ([lower containsString:item.lowercaseString]) return YES;
    }
    return NO;
}

static BOOL PFCaptureIsRouteKey(NSString *key) {
    NSString *lower = key.lowercaseString;
    if (PFCaptureIsSensitiveKey(lower)) return NO;
    NSArray<NSString *> *keys = @[@"route", @"url", @"path", @"location",
                                  @"routerid", @"flutterroute", @"nativeroute",
                                  @"routename", @"urlstring", @"urlpath",
                                  @"deeplink", @"deep_link", @"destination"];
    for (NSString *item in keys) {
        if ([lower containsString:item]) return YES;
    }
    return NO;
}

static NSString *PFCaptureSanitizeURLString(NSString *value) {
    if (value.length == 0) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange schemeRange = [trimmed rangeOfString:@"://"];
    if (schemeRange.location != NSNotFound) {
        NSString *prefix = [trimmed substringToIndex:NSMaxRange(schemeRange)];
        NSString *lowerPrefix = prefix.lowercaseString;
        if (![lowerPrefix isEqualToString:@"fleamarket://"] &&
            ![lowerPrefix isEqualToString:@"xianyu://"] &&
            ![lowerPrefix isEqualToString:@"http://"] &&
            ![lowerPrefix isEqualToString:@"https://"]) {
            return nil;
        }
        NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
        if (components) {
            components.query = nil;
            components.fragment = nil;
            return components.string;
        }
        NSRange queryRange = [trimmed rangeOfString:@"?"];
        if (queryRange.location != NSNotFound) {
            trimmed = [trimmed substringToIndex:queryRange.location];
        }
        NSRange fragmentRange = [trimmed rangeOfString:@"#"];
        if (fragmentRange.location != NSNotFound) {
            trimmed = [trimmed substringToIndex:fragmentRange.location];
        }
        return trimmed;
    }

    NSRange settingsRange = [trimmed.lowercaseString rangeOfString:@"flutter_settings"];
    if (settingsRange.location != NSNotFound) {
        NSRange queryRange = [trimmed rangeOfString:@"?"];
        if (queryRange.location != NSNotFound) trimmed = [trimmed substringToIndex:queryRange.location];
        return trimmed.length > 180 ? [trimmed substringToIndex:180] : trimmed;
    }
    return nil;
}

static void PFCaptureCollectRouteValues(id object,
                                        NSString *keyHint,
                                        NSUInteger depth,
                                        NSMutableArray<NSString *> *output) {
    if (!object || object == [NSNull null] || depth > 5 || output.count >= 12) return;

    if ([object isKindOfClass:[NSString class]]) {
        NSString *value = (NSString *)object;
        NSString *url = PFCaptureSanitizeURLString(value);
        if (url.length) {
            [output addObject:[NSString stringWithFormat:@"%@=%@", keyHint.length ? keyHint : @"route", url]];
        } else if (keyHint.length && PFCaptureIsRouteKey(keyHint) &&
                   value.length > 0 && value.length <= 120 &&
                   [value rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location == NSNotFound) {
            NSString *lower = value.lowercaseString;
            if (![lower containsString:@"bearer "] &&
                ![lower containsString:@"password"] &&
                ![lower containsString:@"token="] &&
                ![lower containsString:@"cookie="]) {
                [output addObject:[NSString stringWithFormat:@"%@=%@", keyHint, value]];
            }
        }
        return;
    }

    if ([object isKindOfClass:[NSURL class]]) {
        NSString *url = PFCaptureSanitizeURLString([(NSURL *)object absoluteString]);
        if (url.length) [output addObject:[NSString stringWithFormat:@"%@=%@", keyHint.length ? keyHint : @"url", url]];
        return;
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            NSString *keyString = [key isKindOfClass:[NSString class]] ? key : @"";
            if (PFCaptureIsSensitiveKey(keyString)) return;
            if (PFCaptureIsRouteKey(keyString)) {
                PFCaptureCollectRouteValues(value, keyString, depth + 1, output);
            } else if ([value isKindOfClass:[NSDictionary class]] ||
                       [value isKindOfClass:[NSArray class]]) {
                PFCaptureCollectRouteValues(value, keyString, depth + 1, output);
            } else if ([value isKindOfClass:[NSString class]]) {
                NSString *url = PFCaptureSanitizeURLString(value);
                if (url.length) PFCaptureCollectRouteValues(value, keyString, depth + 1, output);
            }
        }];
        return;
    }

    if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            PFCaptureCollectRouteValues(value, keyHint, depth + 1, output);
            if (output.count >= 12) break;
        }
        return;
    }

    if (depth < 2) {
        NSArray<NSString *> *keys = @[@"urlString", @"urlPath", @"url", @"route",
                                      @"location", @"flutterRoute", @"nativeRoute",
                                      @"routeName", @"path"];
        for (NSString *key in keys) {
            @try {
                id value = [object valueForKey:key];
                if (value && value != object) {
                    PFCaptureCollectRouteValues(value, key, depth + 1, output);
                }
            } @catch (__unused NSException *exception) {
            }
            if (output.count >= 12) break;
        }
    }
}

static NSString *PFCaptureRouteSummary(id object) {
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    PFCaptureCollectRouteValues(object, @"", 0, values);
    if (values.count == 0) return nil;

    NSOrderedSet<NSString *> *unique = [NSOrderedSet orderedSetWithArray:values];
    return [[unique.array subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)8, unique.count))]
            componentsJoinedByString:@" | "];
}

static BOOL PFCaptureInterestingChannel(NSString *channel) {
    NSString *lower = channel.lowercaseString;
    return [lower containsString:@"route"] ||
           [lower containsString:@"navigation"] ||
           [lower containsString:@"fishcoin"] ||
           [lower containsString:@"settings"] ||
           [lower containsString:@"routerapi"];
}

static NSString *PFCaptureChannelName(id channel) {
    if (!channel) return @"(nil channel)";
    @try {
        id value = [channel valueForKey:@"name"];
        if ([value isKindOfClass:[NSString class]]) return value;
    } @catch (__unused NSException *exception) {
    }
    @try {
        id value = [channel valueForKey:@"channelName"];
        if ([value isKindOfClass:[NSString class]]) return value;
    } @catch (__unused NSException *exception) {
    }
    return NSStringFromClass([channel class]);
}

static void PFCaptureLogRouteEvent(NSString *source, id object) {
    NSString *route = PFCaptureRouteSummary(object);
    if (route.length) {
        PFCaptureLog(@"ROUTE source=%@ %@", source, route);
    } else {
        PFCaptureLog(@"CALL source=%@ argumentClass=%@", source,
                     object ? NSStringFromClass([object class]) : @"(nil)");
    }
}

static BOOL PFCaptureIsBooleanMethod(Method method) {
    char *type = method_copyReturnType(method);
    BOOL result = type && (type[0] == 'B' || type[0] == 'c' || type[0] == 'C');
    free(type);
    return result;
}

static BOOL PFCaptureIsObjectMethod(Method method) {
    char *type = method_copyReturnType(method);
    BOOL result = type && (type[0] == '@' || type[0] == '#');
    free(type);
    return result;
}

static BOOL PFCaptureIsVoidMethod(Method method) {
    char *type = method_copyReturnType(method);
    BOOL result = type && type[0] == 'v';
    free(type);
    return result;
}

static BOOL PFCaptureClassOwnsSelector(Class cls, SEL selector, BOOL isClassMethod) {
    Class target = isClassMethod ? object_getClass(cls) : cls;
    if (!target) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static NSMutableSet<NSString *> *PFCaptureHookRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gPFCaptureInstalledHooks = [NSMutableSet set];
    });
    return gPFCaptureInstalledHooks;
}

static BOOL PFCaptureInstallHook(Class cls,
                                 SEL selector,
                                 BOOL isClassMethod,
                                 IMP replacement,
                                 IMP *originalStorage,
                                 NSUInteger expectedArguments,
                                 char expectedReturnKind) {
    if (!cls || !selector || !replacement || !originalStorage) return NO;

    NSString *sign = isClassMethod ? @"+" : @"-";
    NSString *key = [NSString stringWithFormat:@"%@%@%@", NSStringFromClass(cls), sign,
                     NSStringFromSelector(selector)];
    @synchronized (PFCaptureHookRegistry()) {
        if ([PFCaptureHookRegistry() containsObject:key]) return YES;
        // Only swizzle methods owned by this class. Swizzling an inherited method
        // through a subclass can replace a shared superclass implementation twice.
        if (!PFCaptureClassOwnsSelector(cls, selector, isClassMethod)) return NO;

        Method method = isClassMethod ? class_getClassMethod(cls, selector)
                                      : class_getInstanceMethod(cls, selector);
        if (!method) return NO;

        if (expectedArguments && method_getNumberOfArguments(method) != expectedArguments) {
            PFCaptureLog(@"HOOK_SKIP %@ args=%u expected=%lu",
                         key, method_getNumberOfArguments(method),
                         (unsigned long)expectedArguments);
            return NO;
        }

        char *returnType = method_copyReturnType(method);
        BOOL returnMatches = !expectedReturnKind || (returnType && returnType[0] == expectedReturnKind);
        free(returnType);
        if (!returnMatches) {
            PFCaptureLog(@"HOOK_SKIP %@ unexpected return type", key);
            return NO;
        }

        *originalStorage = method_setImplementation(method, replacement);
        [PFCaptureHookRegistry() addObject:key];
        PFCaptureLog(@"HOOK_OK %@ encoding=%s", key, method_getTypeEncoding(method) ?: "(unknown)");
        return YES;
    }
}

static BOOL PFCaptureRouterOpenURLThreeBool(id self, SEL cmd, id url, id query, id params);
static BOOL PFCaptureRouterOpenURLFourBool(id self, SEL cmd, id url, id query, id params, id uniqueID);
static id PFCaptureRouterOpenURLFourObject(id self, SEL cmd, id url, id query, id params, id uniqueID);
static BOOL PFCaptureSafeOpenURLOneBool(id self, SEL cmd, id url);
static BOOL PFCaptureSafeOpenURLFourBool(id self, SEL cmd, id url, id query, id params, id uniqueID);
static id PFCaptureSafeOpenURLFourObject(id self, SEL cmd, id url, id query, id params, id uniqueID);
static void PFCaptureRouterCallHandler(id self, SEL cmd, Class handlerClass, id object);
static void PFCaptureRouterOpenViewController(id self, SEL cmd, Class routerClass, id object);
static id PFCaptureRouterCreateRouterObject(id self, SEL cmd, id url, id query, id params);

static BOOL PFCaptureInstallRouterFourArgumentHook(Class cls,
                                                    SEL selector,
                                                    BOOL isClassMethod,
                                                    IMP *originalStorage) {
    if (!cls || !selector || !originalStorage) return NO;
    Method method = isClassMethod ? class_getClassMethod(cls, selector)
                                  : class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    if (method_getNumberOfArguments(method) != 6) {
        PFCaptureLog(@"HOOK_SKIP %@%@ args=%u (expected 6)",
                     isClassMethod ? @"+" : @"-", NSStringFromSelector(selector),
                     method_getNumberOfArguments(method));
        return NO;
    }

    if (PFCaptureIsBooleanMethod(method)) {
        return PFCaptureInstallHook(cls, selector, isClassMethod,
                                    isClassMethod ? (IMP)PFCaptureSafeOpenURLFourBool
                                                  : (IMP)PFCaptureRouterOpenURLFourBool,
                                    originalStorage, 6, 0);
    }
    if (PFCaptureIsObjectMethod(method)) {
        return PFCaptureInstallHook(cls, selector, isClassMethod,
                                    isClassMethod ? (IMP)PFCaptureSafeOpenURLFourObject
                                                  : (IMP)PFCaptureRouterOpenURLFourObject,
                                    originalStorage, 6, 0);
    }

    PFCaptureLog(@"HOOK_SKIP %@ unsupported return encoding=%s",
                 NSStringFromSelector(selector), method_getTypeEncoding(method) ?: "(unknown)");
    return NO;
}

static BOOL PFCaptureRouterOpenURLFourBool(id self, SEL cmd, id url, id query, id params, id uniqueID) {
    PFCaptureLogRouteEvent(@"-[FMURLRouter openURL:withQuery:withParams:withUniqueid:]", url);
    BOOL result = ((BOOL (*)(id, SEL, id, id, id, id))gRouterOpen4Original)
        ? ((BOOL (*)(id, SEL, id, id, id, id))gRouterOpen4Original)(self, cmd, url, query, params, uniqueID)
        : NO;
    PFCaptureLog(@"ROUTER_RESULT openURL:withUniqueid: result=%d", result);
    return result;
}

static id PFCaptureRouterOpenURLFourObject(id self, SEL cmd, id url, id query, id params, id uniqueID) {
    PFCaptureLogRouteEvent(@"-[FMURLRouter openURL:withQuery:withParams:withUniqueid:]", url);
    return ((id (*)(id, SEL, id, id, id, id))gRouterOpen4Original)
        ? ((id (*)(id, SEL, id, id, id, id))gRouterOpen4Original)(self, cmd, url, query, params, uniqueID)
        : nil;
}

static BOOL PFCaptureRouterOpenURLThreeBool(id self, SEL cmd, id url, id query, id params) {
    PFCaptureLogRouteEvent(@"-[FMURLRouter openURL:withQuery:withParams:]", url);
    BOOL result = ((BOOL (*)(id, SEL, id, id, id))gRouterOpen3Original)
        ? ((BOOL (*)(id, SEL, id, id, id))gRouterOpen3Original)(self, cmd, url, query, params)
        : NO;
    PFCaptureLog(@"ROUTER_RESULT openURL:withParams: result=%d", result);
    return result;
}

static BOOL PFCaptureSafeOpenURLOneBool(id self, SEL cmd, id url) {
    PFCaptureLogRouteEvent(@"+[FMURLRouter safeOpenURL:]", url);
    BOOL result = ((BOOL (*)(id, SEL, id))gRouterSafeOpen1Original)
        ? ((BOOL (*)(id, SEL, id))gRouterSafeOpen1Original)(self, cmd, url)
        : NO;
    PFCaptureLog(@"ROUTER_RESULT safeOpenURL: result=%d", result);
    return result;
}

static BOOL PFCaptureSafeOpenURLFourBool(id self, SEL cmd, id url, id query, id params, id uniqueID) {
    PFCaptureLogRouteEvent(@"+[FMURLRouter safeOpenURL:withQuery:withParams:withUniqueid:]", url);
    BOOL result = ((BOOL (*)(id, SEL, id, id, id, id))gRouterSafeOpen4Original)
        ? ((BOOL (*)(id, SEL, id, id, id, id))gRouterSafeOpen4Original)(self, cmd, url, query, params, uniqueID)
        : NO;
    PFCaptureLog(@"ROUTER_RESULT safeOpenURL result=%d", result);
    return result;
}

static id PFCaptureSafeOpenURLFourObject(id self, SEL cmd, id url, id query, id params, id uniqueID) {
    PFCaptureLogRouteEvent(@"+[FMURLRouter safeOpenURL:withQuery:withParams:withUniqueid:]", url);
    return ((id (*)(id, SEL, id, id, id, id))gRouterSafeOpen4Original)
        ? ((id (*)(id, SEL, id, id, id, id))gRouterSafeOpen4Original)(self, cmd, url, query, params, uniqueID)
        : nil;
}

static void PFCaptureRouterHandle(id self, SEL cmd, Class routeClass, id object) {
    PFCaptureLog(@"ROUTER_HANDLE class=%@", routeClass ? NSStringFromClass(routeClass) : @"(nil)");
    PFCaptureLogRouteEvent(@"-[FMURLRouter handle:withObject:] object", object);
    if (gRouterHandleOriginal) {
        ((void (*)(id, SEL, Class, id))gRouterHandleOriginal)(self, cmd, routeClass, object);
    }
}

static void PFCaptureRouterCallHandler(id self, SEL cmd, Class handlerClass, id object) {
    PFCaptureLog(@"ROUTER_CALL_HANDLER class=%@", handlerClass ? NSStringFromClass(handlerClass) : @"(nil)");
    PFCaptureLogRouteEvent(@"-[FMURLRouter callHandler:withObject:] object", object);
    if (gRouterCallHandlerOriginal) {
        ((void (*)(id, SEL, Class, id))gRouterCallHandlerOriginal)(self, cmd, handlerClass, object);
    }
}

static void PFCaptureRouterOpenViewController(id self, SEL cmd, Class routerClass, id object) {
    PFCaptureLog(@"ROUTER_OPEN_VIEW_CONTROLLER class=%@", routerClass ? NSStringFromClass(routerClass) : @"(nil)");
    PFCaptureLogRouteEvent(@"-[FMURLRouter openViewController:withObject:] object", object);
    if (gRouterOpenViewControllerOriginal) {
        ((void (*)(id, SEL, Class, id))gRouterOpenViewControllerOriginal)(self, cmd, routerClass, object);
    }
}

static id PFCaptureRouterCreateRouterObject(id self, SEL cmd, id url, id query, id params) {
    PFCaptureLogRouteEvent(@"-[FMURLRouter createRouterObject:withQuery:withParams:] url", url);
    id result = ((id (*)(id, SEL, id, id, id))gRouterCreateRouterObjectOriginal)
        ? ((id (*)(id, SEL, id, id, id))gRouterCreateRouterObjectOriginal)(self, cmd, url, query, params)
        : nil;
    NSString *route = PFCaptureRouteSummary(result);
    if (route.length) PFCaptureLog(@"ROUTER_OBJECT %@", route);
    else PFCaptureLog(@"ROUTER_OBJECT class=%@", result ? NSStringFromClass([result class]) : @"(nil)");
    return result;
}

static id PFCaptureRouterPreProcessURL(id self, SEL cmd, id url) {
    PFCaptureLogRouteEvent(@"-[FMURLRouter preProcessURL:]", url);
    return ((id (*)(id, SEL, id))gRouterPreProcessURLOriginal)
        ? ((id (*)(id, SEL, id))gRouterPreProcessURLOriginal)(self, cmd, url)
        : url;
}

static void PFCaptureUIApplicationOpenURL(id self, SEL cmd, id url, id options, id completion) {
    NSString *route = PFCaptureRouteSummary(url);
    if (route.length) PFCaptureLog(@"SYSTEM_URL_OPEN %@", route);
    if (gUIApplicationOpenURLOriginal) {
        ((void (*)(id, SEL, id, id, id))gUIApplicationOpenURLOriginal)(self, cmd, url, options, completion);
    }
}

static BOOL PFCaptureUIApplicationOpenURLLegacy(id self, SEL cmd, id url) {
    NSString *route = PFCaptureRouteSummary(url);
    if (route.length) PFCaptureLog(@"SYSTEM_URL_OPEN_LEGACY %@", route);
    return ((BOOL (*)(id, SEL, id))gUIApplicationOpenURLLegacyOriginal)
        ? ((BOOL (*)(id, SEL, id))gUIApplicationOpenURLLegacyOriginal)(self, cmd, url)
        : NO;
}

static id PFCaptureMethodChannelInit(id self, SEL cmd, id name, id messenger, id codec) {
    id result = ((id (*)(id, SEL, id, id, id))gMethodChannelInitOriginal)
        ? ((id (*)(id, SEL, id, id, id))gMethodChannelInitOriginal)(self, cmd, name, messenger, codec)
        : self;
    if ([name isKindOfClass:[NSString class]] && PFCaptureInterestingChannel(name)) {
        PFCaptureLog(@"CHANNEL_INIT type=FlutterMethodChannel name=%@", name);
    }
    return result;
}

static id PFCaptureBasicChannelInit(id self, SEL cmd, id name, id messenger, id codec) {
    id result = ((id (*)(id, SEL, id, id, id))gBasicChannelInitOriginal)
        ? ((id (*)(id, SEL, id, id, id))gBasicChannelInitOriginal)(self, cmd, name, messenger, codec)
        : self;
    if ([name isKindOfClass:[NSString class]] && PFCaptureInterestingChannel(name)) {
        PFCaptureLog(@"CHANNEL_INIT type=FlutterBasicMessageChannel name=%@", name);
    }
    return result;
}

static void PFCaptureMethodChannelInvoke(id self, SEL cmd, id methodName, id arguments, id resultCallback) {
    NSString *channel = PFCaptureChannelName(self);
    NSString *routes = PFCaptureRouteSummary(arguments);
    NSString *method = [methodName isKindOfClass:[NSString class]] ? methodName : @"(non-string method)";
    if (PFCaptureInterestingChannel(channel) || PFCaptureInterestingChannel(method) || routes.length) {
        PFCaptureLog(@"FLUTTER_INVOKE channel=%@ method=%@%@", channel, method,
                     routes.length ? [NSString stringWithFormat:@" routes={%@}", routes] : @"");
    }
    if (gMethodChannelInvokeOriginal) {
        ((void (*)(id, SEL, id, id, id))gMethodChannelInvokeOriginal)(self, cmd, methodName, arguments, resultCallback);
    }
}

static void PFCaptureBasicChannelSend(id self, SEL cmd, id message) {
    NSString *channel = PFCaptureChannelName(self);
    NSString *routes = PFCaptureRouteSummary(message);
    if (PFCaptureInterestingChannel(channel) || routes.length) {
        PFCaptureLog(@"FLUTTER_SEND channel=%@%@", channel,
                     routes.length ? [NSString stringWithFormat:@" routes={%@}", routes] : @"");
    }
    if (gBasicChannelSendOriginal) {
        ((void (*)(id, SEL, id))gBasicChannelSendOriginal)(self, cmd, message);
    }
}

static void PFCaptureBasicChannelSendReply(id self, SEL cmd, id message, id reply) {
    NSString *channel = PFCaptureChannelName(self);
    NSString *routes = PFCaptureRouteSummary(message);
    if (PFCaptureInterestingChannel(channel) || routes.length) {
        PFCaptureLog(@"FLUTTER_SEND_REPLY channel=%@%@", channel,
                     routes.length ? [NSString stringWithFormat:@" routes={%@}", routes] : @"");
    }
    if (gBasicChannelSendReplyOriginal) {
        ((void (*)(id, SEL, id, id))gBasicChannelSendReplyOriginal)(self, cmd, message, reply);
    }
}

typedef void (^PFCaptureMessageHandler)(id message, id reply);
typedef void (^PFCaptureMethodCallHandler)(id methodCall, id result);

static void PFCaptureBasicChannelSetHandler(id self, SEL cmd, id handler) {
    if (!handler || !gBasicChannelSetHandlerOriginal) {
        if (gBasicChannelSetHandlerOriginal) {
            ((void (*)(id, SEL, id))gBasicChannelSetHandlerOriginal)(self, cmd, handler);
        }
        return;
    }

    NSString *channel = PFCaptureChannelName(self);
    PFCaptureMessageHandler originalHandler = (PFCaptureMessageHandler)handler;
    PFCaptureMessageHandler wrapped = ^(id message, id reply) {
        NSString *routes = PFCaptureRouteSummary(message);
        if (PFCaptureInterestingChannel(channel) || routes.length) {
            PFCaptureLog(@"FLUTTER_RECEIVE channel=%@%@", channel,
                         routes.length ? [NSString stringWithFormat:@" routes={%@}", routes] : @"");
        }
        originalHandler(message, reply);
    };
    ((void (*)(id, SEL, id))gBasicChannelSetHandlerOriginal)(self, cmd, wrapped);
}

static void PFCaptureMethodChannelSetHandler(id self, SEL cmd, id handler) {
    if (!handler || !gMethodChannelSetHandlerOriginal) {
        if (gMethodChannelSetHandlerOriginal) {
            ((void (*)(id, SEL, id))gMethodChannelSetHandlerOriginal)(self, cmd, handler);
        }
        return;
    }

    NSString *channel = PFCaptureChannelName(self);
    PFCaptureMethodCallHandler originalHandler = (PFCaptureMethodCallHandler)handler;
    PFCaptureMethodCallHandler wrapped = ^(id methodCall, id result) {
        id methodName = nil;
        id arguments = nil;
        @try { methodName = [methodCall valueForKey:@"method"]; } @catch (__unused NSException *exception) {}
        @try { arguments = [methodCall valueForKey:@"arguments"]; } @catch (__unused NSException *exception) {}
        NSString *routes = PFCaptureRouteSummary(arguments);
        NSString *method = [methodName isKindOfClass:[NSString class]] ? methodName : @"(unknown)";
        if (PFCaptureInterestingChannel(channel) || PFCaptureInterestingChannel(method) || routes.length) {
            PFCaptureLog(@"FLUTTER_RECEIVE_METHOD channel=%@ method=%@%@", channel, method,
                         routes.length ? [NSString stringWithFormat:@" routes={%@}", routes] : @"");
        }
        originalHandler(methodCall, result);
    };
    ((void (*)(id, SEL, id))gMethodChannelSetHandlerOriginal)(self, cmd, wrapped);
}

static UIWindow *PFCaptureKeyWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow && !window.hidden && window.alpha > 0.01) return window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {
        if (window.isKeyWindow && !window.hidden && window.alpha > 0.01) return window;
    }
#pragma clang diagnostic pop
    return nil;
}

static UIViewController *PFCaptureTopController(void) {
    UIViewController *controller = PFCaptureKeyWindow().rootViewController;
    while (controller) {
        if (controller.presentedViewController) {
            controller = controller.presentedViewController;
            continue;
        }
        if ([controller isKindOfClass:[UINavigationController class]]) {
            UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
            if (visible) { controller = visible; continue; }
        }
        if ([controller isKindOfClass:[UITabBarController class]]) {
            UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
            if (selected) { controller = selected; continue; }
        }
        break;
    }
    return controller;
}

static NSString *PFCaptureRecentLogText(void) {
    NSError *error = nil;
    NSString *text = [NSString stringWithContentsOfFile:PFCaptureLogPath()
                                               encoding:NSUTF8StringEncoding
                                                  error:&error];
    if (!text.length) return [NSString stringWithFormat:@"暂无日志。路径：%@\n错误：%@",
                              PFCaptureLogPath(), error.localizedDescription ?: @"文件尚未生成"];
    NSUInteger maximumLength = 60000;
    if (text.length > maximumLength) {
        text = [text substringFromIndex:text.length - maximumLength];
        text = [@"(仅显示最后 60000 个字符)\n" stringByAppendingString:text];
    }
    return text;
}

static void PFCaptureExportLog(UIButton *sender) {
    // Let the action sheet dismiss before presenting the system share sheet.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *presenter = PFCaptureTopController();
        if (!presenter || presenter.presentedViewController) {
            PFCaptureLog(@"EXPORT_SKIP no available presenter");
            return;
        }
        NSURL *fileURL = [NSURL fileURLWithPath:PFCaptureLogPath()];
        UIActivityViewController *activity =
            [[UIActivityViewController alloc] initWithActivityItems:@[fileURL]
                                              applicationActivities:nil];
        UIPopoverPresentationController *popover = activity.popoverPresentationController;
        if (popover) {
            popover.sourceView = sender ?: presenter.view;
            popover.sourceRect = sender ? sender.bounds : presenter.view.bounds;
            popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
        }
        [presenter presentViewController:activity animated:YES completion:nil];
    });
}

static void PFCaptureShowMenu(UIButton *sender) {
    UIViewController *presenter = PFCaptureTopController();
    if (!presenter || presenter.presentedViewController) return;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"PiggyHandFish 抓取器"
                                            message:[NSString stringWithFormat:@"已记录路由与 Flutter 通道线索。\n日志：%@", PFCaptureLogPath()]
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"导出抓取日志"
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
        PFCaptureExportLog(sender);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制最近日志"
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = PFCaptureRecentLogText();
        PFCaptureLog(@"RECENT_LOG_COPIED");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIAlertController *done = [UIAlertController alertControllerWithTitle:@"已复制"
                                                                           message:@"最近的抓取日志已复制，可粘贴到聊天中。"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *top = PFCaptureTopController();
            if (top && !top.presentedViewController) [top presentViewController:done animated:YES completion:nil];
        });
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sender;
        popover.sourceRect = sender.bounds;
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}

static void PFCaptureInstallOverlay(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ PFCaptureInstallOverlay(); });
        return;
    }
    UIWindow *window = PFCaptureKeyWindow();
    if (!window) return;

    if (gPFCaptureButton && gPFCaptureButton.superview == window) {
        gPFCaptureButton.hidden = NO;
        return;
    }
    [gPFCaptureButton removeFromSuperview];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = PFCaptureButtonTag;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = @"PiggyHandFish 抓取器，点击查看和导出日志";
    button.backgroundColor = [UIColor colorWithRed:0.82 green:0.18 blue:0.20 alpha:0.97];
    [button setTitle:@"抓取" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.layer.cornerRadius = 8.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.25;
    button.layer.shadowRadius = 4.0;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.layer.zPosition = 1000000.0;
    [button addTarget:PFCaptureTarget()
               action:@selector(pfcaptureButtonTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    // A target object is used instead of an action block to keep the overlay lifetime explicit.
    [window addSubview:button];
    gPFCaptureButton = button;
    UILayoutGuide *safe = window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10.0],
        [button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [button.widthAnchor constraintEqualToConstant:58.0],
        [button.heightAnchor constraintEqualToConstant:34.0]
    ]];

    PFCaptureLog(@"OVERLAY_INSTALLED window=%@", NSStringFromClass(window.class));
}

@interface PFCaptureButtonTarget : NSObject
- (void)pfcaptureButtonTapped:(UIButton *)sender;
@end

@implementation PFCaptureButtonTarget
- (void)pfcaptureButtonTapped:(UIButton *)sender {
    PFCaptureShowMenu(sender);
}
@end

static PFCaptureButtonTarget *PFCaptureTarget(void) {
    static PFCaptureButtonTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [PFCaptureButtonTarget new]; });
    return target;
}

static void PFCaptureInstallOverlayWithTarget(void) {
    // Ensure the target exists before installing an overlay control.
    (void)PFCaptureTarget();
    PFCaptureInstallOverlay();
}

static BOOL PFCaptureClassIsInteresting(NSString *name) {
    NSString *lower = name.lowercaseString;
    NSArray<NSString *> *needles = @[@"fmurlrouter", @"fbnativerouterapi",
                                     @"fbflutterrouterapi", @"fishcoin",
                                     @"coin-game", @"coingame", @"homefishcoin",
                                     @"xflutterviewcontroller", @"routerutil"];
    for (NSString *needle in needles) {
        if ([lower containsString:needle]) return YES;
    }
    return NO;
}

static BOOL PFCaptureSelectorIsInteresting(NSString *selector) {
    NSString *lower = selector.lowercaseString;
    NSArray<NSString *> *needles = @[@"route", @"url", @"channel", @"fish", @"coin",
                                     @"setting", @"open", @"handle", @"push", @"pop",
                                     @"intercept", @"process", @"navigation", @"stack"];
    for (NSString *needle in needles) {
        if ([lower containsString:needle]) return YES;
    }
    return NO;
}

static void PFCaptureLogMethodsForClass(Class cls, BOOL classMethods) {
    Class target = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    NSUInteger emitted = 0;
    for (unsigned int i = 0; i < count && emitted < 80; i++) {
        SEL selector = method_getName(methods[i]);
        NSString *selectorName = NSStringFromSelector(selector);
        if (!PFCaptureSelectorIsInteresting(selectorName)) continue;
        PFCaptureLog(@"RUNTIME_METHOD %c[%s %@] types=%s",
                     classMethods ? '+' : '-', class_getName(cls), selectorName,
                     method_getTypeEncoding(methods[i]) ?: "(unknown)");
        emitted++;
    }
    free(methods);
}

static void PFCaptureWriteRuntimeInventory(void) {
    if (gPFCaptureInventoryWritten) return;

    int capacity = objc_getClassList(NULL, 0);
    if (capacity <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)capacity, sizeof(Class));
    if (!classes) return;
    int count = objc_getClassList(classes, capacity);

    NSUInteger interestingCount = 0;
    for (int i = 0; i < count; i++) {
        const char *rawName = class_getName(classes[i]);
        if (!rawName) continue;
        NSString *name = [NSString stringWithUTF8String:rawName];
        if (!name || !PFCaptureClassIsInteresting(name)) continue;
        interestingCount++;
    }
    if (interestingCount == 0) {
        free(classes);
        return;
    }

    PFCaptureLog(@"=== Runtime inventory begin: classes=%d interesting=%lu ===",
                 count, (unsigned long)interestingCount);

    NSUInteger emittedClasses = 0;
    for (int i = 0; i < count && emittedClasses < 120; i++) {
        const char *rawName = class_getName(classes[i]);
        if (!rawName) continue;
        NSString *name = [NSString stringWithUTF8String:rawName];
        if (!name || !PFCaptureClassIsInteresting(name)) continue;

        PFCaptureLog(@"RUNTIME_CLASS %s", rawName);
        PFCaptureLogMethodsForClass(classes[i], NO);
        PFCaptureLogMethodsForClass(classes[i], YES);
        emittedClasses++;
    }

    PFCaptureLog(@"=== Runtime inventory end: emitted=%lu ===", (unsigned long)emittedClasses);
    gPFCaptureInventoryWritten = YES;
    free(classes);
}


static void PFCaptureRouterUtilOpenUrl(id self, SEL cmd, id url) {
    PFCaptureLogRouteEvent(@"+[IFMatrix.RouterUtil openUrl:]", url);
    if (gRouterUtilOpenUrlOriginal) {
        ((void (*)(id, SEL, id))gRouterUtilOpenUrlOriginal)(self, cmd, url);
    }
}

static void PFCaptureFlutterRouterPushRoute(id self, SEL cmd, id route, id completion) {
    PFCaptureLogRouteEvent(@"-[FBFlutterRouterApi pushRoute:completion:]", route);
    if (gFlutterRouterPushRouteOriginal) {
        ((void (*)(id, SEL, id, id))gFlutterRouterPushRouteOriginal)(self, cmd, route, completion);
    }
}

static void PFCaptureFlutterRouterPopRoute(id self, SEL cmd, id route, id completion) {
    PFCaptureLogRouteEvent(@"-[FBFlutterRouterApi popRoute:completion:]", route);
    if (gFlutterRouterPopRouteOriginal) {
        ((void (*)(id, SEL, id, id))gFlutterRouterPopRouteOriginal)(self, cmd, route, completion);
    }
}

static void PFCaptureFlutterRouterRemoveRoute(id self, SEL cmd, id route, id completion) {
    PFCaptureLogRouteEvent(@"-[FBFlutterRouterApi removeRoute:completion:]", route);
    if (gFlutterRouterRemoveRouteOriginal) {
        ((void (*)(id, SEL, id, id))gFlutterRouterRemoveRouteOriginal)(self, cmd, route, completion);
    }
}

static BOOL PFCaptureInterestingController(UIViewController *controller) {
    if (!controller) return NO;
    NSString *name = NSStringFromClass(controller.class).lowercaseString;
    return [name containsString:@"setting"] ||
           [name containsString:@"flutter"] ||
           [name containsString:@"xflutter"] ||
           [name containsString:@"webview"] ||
           [name containsString:@"router"] ||
           [name containsString:@"profile"];
}

static void PFCaptureNavigationPush(id self, SEL cmd, UIViewController *viewController, BOOL animated) {
    if (PFCaptureInterestingController(viewController)) {
        PFCaptureLog(@"NATIVE_NAV_PUSH controller=%@ title=%@",
                     NSStringFromClass(viewController.class),
                     viewController.title ?: @"(no title)");
    }
    if (gNavigationPushOriginal) {
        ((void (*)(id, SEL, id, BOOL))gNavigationPushOriginal)(self, cmd, viewController, animated);
    }
}

static void PFCaptureViewControllerPresent(id self, SEL cmd, UIViewController *viewController,
                                           BOOL animated, id completion) {
    if (PFCaptureInterestingController(viewController)) {
        PFCaptureLog(@"NATIVE_PRESENT controller=%@ title=%@",
                     NSStringFromClass(viewController.class),
                     viewController.title ?: @"(no title)");
    }
    if (gViewControllerPresentOriginal) {
        ((void (*)(id, SEL, id, BOOL, id))gViewControllerPresentOriginal)
            (self, cmd, viewController, animated, completion);
    }
}

static void PFCaptureInstallHooks(void) {
    Class router = NSClassFromString(@"FMURLRouter");
    if (router) {
        SEL openThreeSelector = sel_registerName("openURL:withQuery:withParams:");
        Method openThreeMethod = class_getInstanceMethod(router, openThreeSelector);
        if (openThreeMethod && method_getNumberOfArguments(openThreeMethod) == 5 &&
            PFCaptureIsBooleanMethod(openThreeMethod)) {
            PFCaptureInstallHook(router, openThreeSelector, NO,
                                 (IMP)PFCaptureRouterOpenURLThreeBool,
                                 &gRouterOpen3Original, 5, 'B');
        } else {
            PFCaptureLog(@"HOOK_SKIP -[FMURLRouter openURL:withQuery:withParams:] unavailable or unexpected signature");
        }

        PFCaptureInstallRouterFourArgumentHook(
            router, sel_registerName("openURL:withQuery:withParams:withUniqueid:"),
            NO, &gRouterOpen4Original);

        SEL safeOneSelector = sel_registerName("safeOpenURL:");
        Method safeOneMethod = class_getClassMethod(router, safeOneSelector);
        if (safeOneMethod && method_getNumberOfArguments(safeOneMethod) == 3 &&
            PFCaptureIsBooleanMethod(safeOneMethod)) {
            PFCaptureInstallHook(router, safeOneSelector, YES,
                                 (IMP)PFCaptureSafeOpenURLOneBool,
                                 &gRouterSafeOpen1Original, 3, 'B');
        } else {
            PFCaptureLog(@"HOOK_SKIP +[FMURLRouter safeOpenURL:] unavailable or unexpected signature");
        }
        PFCaptureInstallRouterFourArgumentHook(
            router, sel_registerName("safeOpenURL:withQuery:withParams:withUniqueid:"),
            YES, &gRouterSafeOpen4Original);

        SEL handleSelector = sel_registerName("handle:withObject:");
        Method handleMethod = class_getInstanceMethod(router, handleSelector);
        if (handleMethod && method_getNumberOfArguments(handleMethod) == 4 &&
            PFCaptureIsVoidMethod(handleMethod)) {
            PFCaptureInstallHook(router, handleSelector, NO, (IMP)PFCaptureRouterHandle,
                                 &gRouterHandleOriginal, 4, 'v');
        }

        SEL callHandlerSelector = sel_registerName("callHandler:withObject:");
        Method callHandlerMethod = class_getInstanceMethod(router, callHandlerSelector);
        if (callHandlerMethod && method_getNumberOfArguments(callHandlerMethod) == 4 &&
            PFCaptureIsVoidMethod(callHandlerMethod)) {
            PFCaptureInstallHook(router, callHandlerSelector, NO, (IMP)PFCaptureRouterCallHandler,
                                 &gRouterCallHandlerOriginal, 4, 'v');
        }

        SEL openVCSelector = sel_registerName("openViewController:withObject:");
        Method openVCMethod = class_getInstanceMethod(router, openVCSelector);
        if (openVCMethod && method_getNumberOfArguments(openVCMethod) == 4 &&
            PFCaptureIsVoidMethod(openVCMethod)) {
            PFCaptureInstallHook(router, openVCSelector, NO, (IMP)PFCaptureRouterOpenViewController,
                                 &gRouterOpenViewControllerOriginal, 4, 'v');
        } else {
            PFCaptureLog(@"HOOK_SKIP -[FMURLRouter openViewController:withObject:] unavailable or unexpected signature");
        }

        SEL createRouterObjectSelector = sel_registerName("createRouterObject:withQuery:withParams:");
        Method createRouterObjectMethod = class_getInstanceMethod(router, createRouterObjectSelector);
        if (createRouterObjectMethod && method_getNumberOfArguments(createRouterObjectMethod) == 5 &&
            PFCaptureIsObjectMethod(createRouterObjectMethod)) {
            PFCaptureInstallHook(router, createRouterObjectSelector, NO, (IMP)PFCaptureRouterCreateRouterObject,
                                 &gRouterCreateRouterObjectOriginal, 5, 0);
        }

        SEL preProcessSelector = sel_registerName("preProcessURL:");
        Method preProcessMethod = class_getInstanceMethod(router, preProcessSelector);
        if (preProcessMethod && method_getNumberOfArguments(preProcessMethod) == 3 &&
            PFCaptureIsObjectMethod(preProcessMethod)) {
            PFCaptureInstallHook(router, preProcessSelector, NO, (IMP)PFCaptureRouterPreProcessURL,
                                 &gRouterPreProcessURLOriginal, 3, 0);
        }
    }

    // The runtime inventory showed this high-level URL entry on the tested build.
    Class routerUtil = NSClassFromString(@"IFMatrix.RouterUtil");
    SEL utilOpenSelector = sel_registerName("openUrl:");
    Method utilOpenMethod = routerUtil ? class_getClassMethod(routerUtil, utilOpenSelector) : NULL;
    if (utilOpenMethod && method_getNumberOfArguments(utilOpenMethod) == 3 &&
        PFCaptureIsVoidMethod(utilOpenMethod)) {
        PFCaptureInstallHook(routerUtil, utilOpenSelector, YES,
                             (IMP)PFCaptureRouterUtilOpenUrl,
                             &gRouterUtilOpenUrlOriginal, 3, 'v');
    }

    // The actual app exposes these native-to-Flutter router methods in FBFlutterRouterApi.
    Class flutterRouterAPI = NSClassFromString(@"FBFlutterRouterApi");
    if (flutterRouterAPI) {
        struct {
            SEL selector;
            IMP replacement;
            IMP *original;
        } routeHooks[] = {
            { sel_registerName("pushRoute:completion:"), (IMP)PFCaptureFlutterRouterPushRoute, &gFlutterRouterPushRouteOriginal },
            { sel_registerName("popRoute:completion:"), (IMP)PFCaptureFlutterRouterPopRoute, &gFlutterRouterPopRouteOriginal },
            { sel_registerName("removeRoute:completion:"), (IMP)PFCaptureFlutterRouterRemoveRoute, &gFlutterRouterRemoveRouteOriginal }
        };
        for (NSUInteger i = 0; i < sizeof(routeHooks) / sizeof(routeHooks[0]); i++) {
            Method method = class_getInstanceMethod(flutterRouterAPI, routeHooks[i].selector);
            if (method && method_getNumberOfArguments(method) == 4 &&
                PFCaptureIsVoidMethod(method)) {
                PFCaptureInstallHook(flutterRouterAPI, routeHooks[i].selector, NO,
                                     routeHooks[i].replacement, routeHooks[i].original, 4, 'v');
            }
        }
    }

    Class navigationClass = UINavigationController.class;
    SEL pushSelector = sel_registerName("pushViewController:animated:");
    Method pushMethod = class_getInstanceMethod(navigationClass, pushSelector);
    if (pushMethod && method_getNumberOfArguments(pushMethod) == 4 &&
        PFCaptureIsVoidMethod(pushMethod)) {
        PFCaptureInstallHook(navigationClass, pushSelector, NO, (IMP)PFCaptureNavigationPush,
                             &gNavigationPushOriginal, 4, 'v');
    }

    Class viewControllerClass = UIViewController.class;
    SEL presentSelector = sel_registerName("presentViewController:animated:completion:");
    Method presentMethod = class_getInstanceMethod(viewControllerClass, presentSelector);
    if (presentMethod && method_getNumberOfArguments(presentMethod) == 5 &&
        PFCaptureIsVoidMethod(presentMethod)) {
        PFCaptureInstallHook(viewControllerClass, presentSelector, NO, (IMP)PFCaptureViewControllerPresent,
                             &gViewControllerPresentOriginal, 5, 'v');
    }

    Class appClass = UIApplication.class;
    SEL openSelector = sel_registerName("openURL:options:completionHandler:");
    Method openMethod = class_getInstanceMethod(appClass, openSelector);
    if (openMethod && method_getNumberOfArguments(openMethod) == 5 &&
        PFCaptureIsVoidMethod(openMethod)) {
        PFCaptureInstallHook(appClass, openSelector, NO, (IMP)PFCaptureUIApplicationOpenURL,
                             &gUIApplicationOpenURLOriginal, 5, 'v');
    }

    SEL legacySelector = sel_registerName("openURL:");
    Method legacyMethod = class_getInstanceMethod(appClass, legacySelector);
    if (legacyMethod && method_getNumberOfArguments(legacyMethod) == 3 &&
        PFCaptureIsBooleanMethod(legacyMethod)) {
        PFCaptureInstallHook(appClass, legacySelector, NO, (IMP)PFCaptureUIApplicationOpenURLLegacy,
                             &gUIApplicationOpenURLLegacyOriginal, 3, 0);
    }

    Class methodChannel = NSClassFromString(@"FlutterMethodChannel");
    if (methodChannel) {
        SEL initSelector = sel_registerName("initWithName:binaryMessenger:codec:");
        Method initMethod = class_getInstanceMethod(methodChannel, initSelector);
        if (initMethod && method_getNumberOfArguments(initMethod) == 5 &&
            PFCaptureIsObjectMethod(initMethod)) {
            PFCaptureInstallHook(methodChannel, initSelector, NO, (IMP)PFCaptureMethodChannelInit,
                                 &gMethodChannelInitOriginal, 5, 0);
        }

        SEL invokeSelector = sel_registerName("invokeMethod:arguments:result:");
        Method invokeMethod = class_getInstanceMethod(methodChannel, invokeSelector);
        if (invokeMethod && method_getNumberOfArguments(invokeMethod) == 5 &&
            PFCaptureIsVoidMethod(invokeMethod)) {
            PFCaptureInstallHook(methodChannel, invokeSelector, NO, (IMP)PFCaptureMethodChannelInvoke,
                                 &gMethodChannelInvokeOriginal, 5, 'v');
        }

        SEL setHandlerSelector = sel_registerName("setMethodCallHandler:");
        Method setHandlerMethod = class_getInstanceMethod(methodChannel, setHandlerSelector);
        if (setHandlerMethod && method_getNumberOfArguments(setHandlerMethod) == 3 &&
            PFCaptureIsVoidMethod(setHandlerMethod)) {
            PFCaptureInstallHook(methodChannel, setHandlerSelector, NO, (IMP)PFCaptureMethodChannelSetHandler,
                                 &gMethodChannelSetHandlerOriginal, 3, 'v');
        }
    }

    Class basicChannel = NSClassFromString(@"FlutterBasicMessageChannel");
    if (basicChannel) {
        SEL initSelector = sel_registerName("initWithName:binaryMessenger:codec:");
        Method initMethod = class_getInstanceMethod(basicChannel, initSelector);
        if (initMethod && method_getNumberOfArguments(initMethod) == 5 &&
            PFCaptureIsObjectMethod(initMethod)) {
            PFCaptureInstallHook(basicChannel, initSelector, NO, (IMP)PFCaptureBasicChannelInit,
                                 &gBasicChannelInitOriginal, 5, 0);
        }

        SEL sendSelector = sel_registerName("sendMessage:");
        Method sendMethod = class_getInstanceMethod(basicChannel, sendSelector);
        if (sendMethod && method_getNumberOfArguments(sendMethod) == 3 &&
            PFCaptureIsVoidMethod(sendMethod)) {
            PFCaptureInstallHook(basicChannel, sendSelector, NO, (IMP)PFCaptureBasicChannelSend,
                                 &gBasicChannelSendOriginal, 3, 'v');
        }

        SEL sendReplySelector = sel_registerName("sendMessage:reply:");
        Method sendReplyMethod = class_getInstanceMethod(basicChannel, sendReplySelector);
        if (sendReplyMethod && method_getNumberOfArguments(sendReplyMethod) == 4 &&
            PFCaptureIsVoidMethod(sendReplyMethod)) {
            PFCaptureInstallHook(basicChannel, sendReplySelector, NO, (IMP)PFCaptureBasicChannelSendReply,
                                 &gBasicChannelSendReplyOriginal, 4, 'v');
        }

        SEL setHandlerSelector = sel_registerName("setMessageHandler:");
        Method setHandlerMethod = class_getInstanceMethod(basicChannel, setHandlerSelector);
        if (setHandlerMethod && method_getNumberOfArguments(setHandlerMethod) == 3 &&
            PFCaptureIsVoidMethod(setHandlerMethod)) {
            PFCaptureInstallHook(basicChannel, setHandlerSelector, NO, (IMP)PFCaptureBasicChannelSetHandler,
                                 &gBasicChannelSetHandlerOriginal, 3, 'v');
        }
    }
}

static void PFCaptureScheduleRetry(void) {
    if (gPFCaptureRetryScheduled) return;
    gPFCaptureRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gPFCaptureRetryScheduled = NO;
        gPFCaptureRetryCount++;
        PFCaptureInstallHooks();
        PFCaptureWriteRuntimeInventory();
        PFCaptureInstallOverlayWithTarget();
        if (gPFCaptureRetryCount < 90) PFCaptureScheduleRetry();
        else PFCaptureLog(@"HOOK_RETRY_WINDOW_ENDED installed=%lu",
                          (unsigned long)PFCaptureHookRegistry().count);
    });
}

static void PFCaptureStart(void) {
    PFCaptureLog(@"LOAD_PROBE constructor=executed bundle=%@ version=%@ path=%@",
                 NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)",
                 [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"(unknown)",
                 PFCaptureLogPath());

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *rawPath = _dyld_get_image_name(i);
        if (!rawPath) continue;
        NSString *path = [NSString stringWithUTF8String:rawPath];
        NSString *lower = path.lowercaseString;
        if ([lower containsString:@"runner"] ||
            [lower containsString:@"/flutter.framework/flutter"] ||
            [lower containsString:@"piggyhandfish"]) {
            PFCaptureLog(@"LOADED_IMAGE %@", path.lastPathComponent);
        }
    }

    PFCaptureInstallHooks();
    PFCaptureWriteRuntimeInventory();
    PFCaptureInstallOverlayWithTarget();
    PFCaptureScheduleRetry();

    if (!gPFCaptureActiveObserver) {
        gPFCaptureActiveObserver =
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                             object:nil
                                                              queue:NSOperationQueue.mainQueue
                                                         usingBlock:^(__unused NSNotification *notification) {
                PFCaptureLog(@"APP_BECAME_ACTIVE bundle=%@",
                             NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)");
                gPFCaptureRetryCount = 0;
                PFCaptureInstallHooks();
                PFCaptureWriteRuntimeInventory();
                PFCaptureInstallOverlayWithTarget();
                PFCaptureScheduleRetry();
            }];
    }
}

__attribute__((constructor))
static void PiggyHandFishCaptureInitialize(void) {
    @autoreleasepool {
        NSLog(@"[PiggyHandFish-Capture] dylib constructor executed");
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                PFCaptureStart();
            }
        });
    }
}
