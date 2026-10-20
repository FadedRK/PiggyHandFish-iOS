#import <Foundation/Foundation.h>
#import "PFConfig.h"
#import "PFLogger.h"
#import "PFScout.h"
#import "PFPluginEntry.h"

static NSString *PFBundleValue(NSString *key) {
    id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:key];
    return [value isKindOfClass:[NSString class]] ? value : @"(unknown)";
}

static void PFStart(void) {
    NSLog(@"[PiggyHandFish] PFStart entered");
    PFLog(@"=== PiggyHandFish iOS reconnaissance loaded ===");
    PFLog(@"Bundle identifier: %@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(unknown)");
    PFLog(@"App version: %@", PFBundleValue(@"CFBundleShortVersionString"));
    PFLog(@"Build: %@", PFBundleValue(@"CFBundleVersion"));

    // Install the floating plugin entry before starting the potentially verbose runtime scan.
    PFInstallPluginEntry();

    if (PFGetConfig().enabled) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            PFStartScout();
        });
    } else {
        PFLog(@"Reconnaissance is disabled by configuration.");
    }
}

__attribute__((constructor))
static void PiggyHandFishInitialize(void) {
    NSLog(@"[PiggyHandFish] dylib constructor invoked");
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                PFStart();
            }
        });
    }
}
