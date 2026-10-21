#import "PFFishTaskRules.h"
NSString * const PFFishTaskListAPI=@"mtop.taobao.idle.task.queryolivertasklist";
NSString * const PFFishTaskBenefitAPI=@"mtop.taobao.idle.task.getolivertaskbenefit";
NSString * const PFFishTaskTriggerAPI=@"mtop.taobao.idle.task.uploadolivertasktrigger";
NSString * const PFFishNextFreshAPI=@"mtop.taobao.idlehome.idle.coin.nextfresh";
NSString * const PFFishSearchAPI=@"mtop.taobao.idlemtopsearch.search";
NSString * const PFFishAdQueryAPI=@"mtop.taobao.idle.play.ad.query";
NSString * const PFFishAdEventAPI=@"mtop.taobao.idle.play.ad.event.push";
NSString * const PFFishAdEventQueryAPI=@"mtop.taobao.idle.play.ad.event.query";
NSString * const PFFishSigninAPI=@"mtop.taobao.idle.coin.signin";
NSString * const PFFishPlaySignAPI=@"mtop.taobao.idle.play.sign.in";
NSString * const PFFishMapInitAPI=@"mtop.taobao.idle.treasure.hunt.map.init";
NSString * const PFFishMapRollAPI=@"mtop.taobao.idle.treasure.hunt.map.roll";
NSString * const PFFishPropListAPI=@"mtop.taobao.idle.play.prop.list";
NSString * const PFFishPropUseAPI=@"mtop.taobao.idle.play.prop.use";
NSString * const PFFishPolishAPI=@"mtop.taobao.idle.item.polish";
NSString * const PFFishShopBenefitAPI=@"mtop.taobao.idle.startup.shop.daily.benefit";
NSString * const PFFishLotteryFeedsAPI=@"mtop.taobao.idle.coin.lottery.feeds";
NSString * const PFFishLotteryBetAPI=@"mtop.taobao.idle.coin.lottery.bet";
NSInteger const PFFishTaskSceneID=496;
@implementation PFFishTask @end
static NSString *S(id x){return [x isKindOfClass:NSString.class]?x:(x?[x description]:@"");}
static NSDictionary *D(id x){return [x isKindOfClass:NSDictionary.class]?x:nil;}
BOOL PFFishTaskNeedsClaim(NSDictionary *t){NSDictionary*b=D(t[@"taskBenefitDTO"]);NSString*s=S(t[@"idleTaskStatus"]);BOOL n=[b[@"needBenefit"] boolValue]||[S(b[@"needBenefit"]) isEqualToString:@"true"];return [s isEqualToString:@"AWARD"]||([s isEqualToString:@"COMPLETE"]&&n);}
PFFishTaskKind PFFishClassifyTask(NSDictionary*t){if(PFFishTaskNeedsClaim(t))return PFFishTaskKindClaim;if(![S(t[@"idleTaskStatus"]) isEqualToString:@"ACCEPTED"])return PFFishTaskKindUnknown;NSDictionary*m=D(t[@"materialDTO"]);NSString*a=S(m[@"action"]),*l=a.lowercaseString,*title=S(m[@"title"]).lowercaseString;if([a containsString:@"showAds"]&&[a containsString:@"adType=ecMall"])return PFFishTaskKindECMallAd;if([l containsString:@"search.html"]||[title containsString:@"搜一搜"]||[title containsString:@"搜索"])return PFFishTaskKindSearch;if([a containsString:@"idleCoinFeesAnchor"])return PFFishTaskKindBrowse;if([S(m[@"actionType"]) isEqualToString:@"TREASURE"]||[title containsString:@"夺宝"]||[title containsString:@"寻宝"])return PFFishTaskKindTreasure;return PFFishTaskKindTrigger;}
NSArray<PFFishTask*>*PFFishParseTaskListResponse(NSDictionary*r){NSArray*l=D(r[@"data"])[@"taskList"];if(![l isKindOfClass:NSArray.class])return @[];NSMutableArray*o=[NSMutableArray array];for(NSDictionary*x in l){if(![x isKindOfClass:NSDictionary.class])continue;PFFishTask*t=[PFFishTask new];NSDictionary*m=D(x[@"materialDTO"]),*p=D(x[@"progressDTO"]),*b=D(x[@"taskBenefitDTO"]);t.raw=x;t.deliveryID=S(x[@"deliveryId"]);t.status=S(x[@"idleTaskStatus"]);t.sceneID=S(x[@"sceneId"]);t.title=S(m[@"title"]);t.actionType=S(m[@"actionType"]);t.action=S(m[@"action"]);t.needBenefit=[b[@"needBenefit"] boolValue];t.times=[p[@"times"] integerValue];t.maxTimes=[p[@"maxTimes"] integerValue];t.kind=PFFishClassifyTask(x);if(t.deliveryID.length)[o addObject:t];}return o;}
NSDictionary*PFFishTriggerParameters(PFFishTask*t){if(!t.deliveryID.length)return @{};NSMutableDictionary*p=[@{@"sceneId":@(496),@"deliveryId":t.deliveryID}mutableCopy];NSURLComponents*c=[NSURLComponents componentsWithString:t.action];for(NSString*k in @[@"implId",@"channelSrp",@"adPositionCode",@"adOrderPositionCode",@"refpid",@"k_usetanx"])for(NSURLQueryItem*q in c.queryItems)if([q.name isEqualToString:k]&&q.value.length){p[k]=q.value;break;}NSString*f=S(t.raw[@"fromToken"]),*g=S(t.raw[@"groupId"]);if(f.length)p[@"fromToken"]=f;if(g.length)p[@"groupId"]=@([g longLongValue]);return p;}
NSDictionary*PFFishSearchTriggerParameters(PFFishTask*t){return PFFishTriggerParameters(t);}
