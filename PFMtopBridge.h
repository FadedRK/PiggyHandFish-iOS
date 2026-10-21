#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a read-only MTOP reconnaissance bridge. It does not modify requests
/// or responses; it records the native classes/methods and HTTP MTOP traffic
/// needed to map the Android task rules onto the iOS protocol stack.
FOUNDATION_EXPORT void PFInstallMtopBridge(void);

NS_ASSUME_NONNULL_END
