#import "PFConfig.h"

PFConfig *PFGetConfig(void) {
    static PFConfig *config;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        config = [PFConfig new];
        config.enabled = YES;
        config.logClasses = YES;
        config.logMethods = NO;
        config.logStacks = NO;
        config.classRegex = @"(?i)(idle|fish|task|coin|reward)";
        config.methodRegex = @".*";
        config.maxClasses = 120;
        config.maxMethodsPerClass = 80;
    });
    return config;
}
