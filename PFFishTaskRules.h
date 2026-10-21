#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const PFFishTaskListAPI;
FOUNDATION_EXPORT NSString * const PFFishTaskBenefitAPI;
FOUNDATION_EXPORT NSString * const PFFishTaskTriggerAPI;
FOUNDATION_EXPORT NSString * const PFFishNextFreshAPI;
FOUNDATION_EXPORT NSString * const PFFishSearchAPI;
FOUNDATION_EXPORT NSString * const PFFishAdQueryAPI;
FOUNDATION_EXPORT NSString * const PFFishAdEventAPI;
FOUNDATION_EXPORT NSString * const PFFishAdEventQueryAPI;
FOUNDATION_EXPORT NSString * const PFFishSigninAPI;
FOUNDATION_EXPORT NSString * const PFFishPlaySignAPI;
FOUNDATION_EXPORT NSString * const PFFishMapInitAPI;
FOUNDATION_EXPORT NSString * const PFFishMapRollAPI;
FOUNDATION_EXPORT NSString * const PFFishPropListAPI;
FOUNDATION_EXPORT NSString * const PFFishPropUseAPI;
FOUNDATION_EXPORT NSString * const PFFishPolishAPI;
FOUNDATION_EXPORT NSString * const PFFishShopBenefitAPI;
FOUNDATION_EXPORT NSString * const PFFishLotteryFeedsAPI;
FOUNDATION_EXPORT NSString * const PFFishLotteryBetAPI;
FOUNDATION_EXPORT NSInteger const PFFishTaskSceneID;

typedef NS_ENUM(NSInteger, PFFishTaskKind) {
    PFFishTaskKindUnknown = 0,
    PFFishTaskKindClaim,
    PFFishTaskKindTrigger,
    PFFishTaskKindSearch,
    PFFishTaskKindBrowse,
    PFFishTaskKindECMallAd,
    PFFishTaskKindTreasure,
};

@interface PFFishTask : NSObject
@property(nonatomic, copy) NSString *deliveryID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *status;
@property(nonatomic, copy) NSString *actionType;
@property(nonatomic, copy) NSString *action;
@property(nonatomic, copy) NSString *sceneID;
@property(nonatomic, assign) BOOL needBenefit;
@property(nonatomic, assign) NSInteger times;
@property(nonatomic, assign) NSInteger maxTimes;
@property(nonatomic, assign) PFFishTaskKind kind;
@property(nonatomic, strong) NSDictionary *raw;
@end

FOUNDATION_EXPORT NSArray<PFFishTask *> *PFFishParseTaskListResponse(NSDictionary *response);
FOUNDATION_EXPORT PFFishTaskKind PFFishClassifyTask(NSDictionary *task);
FOUNDATION_EXPORT BOOL PFFishTaskNeedsClaim(NSDictionary *task);
FOUNDATION_EXPORT NSDictionary *PFFishTriggerParameters(PFFishTask *task);
FOUNDATION_EXPORT NSDictionary *PFFishSearchTriggerParameters(PFFishTask *task);

NS_ASSUME_NONNULL_END
