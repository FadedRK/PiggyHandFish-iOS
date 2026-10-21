#import <Foundation/Foundation.h>

/// Installs a read-only network observation layer used to identify the native
/// request path used by Xianyu/MTOP. It does not create, modify, replay, or
/// cancel requests.
void PFInstallNetworkProbe(void);
