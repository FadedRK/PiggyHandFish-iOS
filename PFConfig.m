#import "PFConfig.h"

@implementation PFConfig
@end

PFConfig *PFGetConfig(void) {
    static PFConfig *config;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        config = [PFConfig new];
        config.enabled = YES;
        config.logClasses = YES;
        config.logMethods = YES;
        config.logClassMethods = YES;
        config.logStacks = NO;

        // Candidates from static inspection of the supplied ARM64 main executable.
        // Runtime presence and call paths still need to be confirmed on-device.
        config.classRegex = @"(?i)(FMCoinGame|FishCoin|FishSyncJumpNewFishCoinEventObject|HomeFishCoinEntranceView|AppIntentFishCoin|WVFishCoin|IdleCoinGame)";
        config.methodRegex = @"(?i)(coin|fish|task|game|intercept|jump|url|process|sign|reward|methodcall|invoke)";
        config.maxClasses = 80;
        config.maxMethodsPerClass = 100;
    });
    return config;
}
