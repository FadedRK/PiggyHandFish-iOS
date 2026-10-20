#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PFActionCompletion)(BOOL success, NSString *message);

@interface PFAction : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *detail;
@end

FOUNDATION_EXPORT NSArray<PFAction *> *PFRegisteredActions(void);
FOUNDATION_EXPORT void PFPerformAction(NSString *identifier,
                                       PFActionCompletion _Nullable completion);

NS_ASSUME_NONNULL_END
