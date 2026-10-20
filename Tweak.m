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
    PFLog(@"=== PiggyHandFish iOS reconnaissance loaded ===");
    PFLog(@"Bundle identifier: %@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(unknown)");
    PFLog(@"App version: %@", PFBundleValue(@"CFBundleShortVersionString"));
    PFLog(@"Build: %@", PFBundleValue(@"CFBundleVersion"));

    PFInstallPluginEntry();

    if (PFGetConfig().enabled) {
        PFStartScout();
    } else {
        PFLog(@"Reconnaissance is disabled by configuration.");
    }
}

__attribute__((constructor))
static void PiggyHandFishInitialize(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                PFStart();
            }
        });
    }
}
