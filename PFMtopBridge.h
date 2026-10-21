#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a read-only MTOP class/method reconnaissance bridge. It does not
/// modify requests or responses; it maps the native iOS protocol stack needed
/// to host the Android-derived task rules.
FOUNDATION_EXPORT void PFInstallMtopBridge(void);

NS_ASSUME_NONNULL_END
