#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PFConfig : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL logClasses;
@property (nonatomic, assign) BOOL logMethods;
@property (nonatomic, assign) BOOL logClassMethods;
@property (nonatomic, assign) BOOL logStacks;
@property (nonatomic, copy) NSString *classRegex;
@property (nonatomic, copy) NSString *methodRegex;
@property (nonatomic, assign) NSUInteger maxClasses;
@property (nonatomic, assign) NSUInteger maxMethodsPerClass;
@end

FOUNDATION_EXPORT PFConfig *PFGetConfig(void);

NS_ASSUME_NONNULL_END
