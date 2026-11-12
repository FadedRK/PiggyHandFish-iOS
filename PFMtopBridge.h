#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a read-only MTOP class/method reconnaissance bridge. It does not
/// modify requests or responses; it maps the native iOS protocol stack needed
/// to host the Android-derived task rules.
FOUNDATION_EXPORT void PFInstallMtopBridge(void);

/// Resolve an in-process anonymous task reference using the same map used by
/// MTOP request logging. Raw identifiers are never returned or logged.
FOUNDATION_EXPORT NSString * _Nullable PFTaskReferenceForIdentifiers(id _Nullable sceneID,
                                                                       id _Nullable deliveryID);

NS_ASSUME_NONNULL_END
