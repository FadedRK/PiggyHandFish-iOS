# Static inspection notes: Runner

## Scope

A local copy of the user-supplied executable `Runner` was inspected with Mach-O metadata and strings/symbols. The executable is **not included** in this repository. This report records names observed statically; it does not claim that runtime behavior or a call chain has been validated.

## File format

- Mach-O 64-bit executable
- ARM64 architecture
- About 183.8 MB
- Contains Objective-C sections (`__objc_classname`, `__objc_methname`, `__objc_methtype`) and Swift metadata sections (`__swift5_*`).
- The executable refers to `@rpath/Flutter.framework/Flutter`, consistent with the binary including Flutter-related components.

## Xianyu identity indicators

Static strings include:

- `com.taobao.fleamarket`
- `idlefish_im_core`
- `@(#)PROGRAM:idlefish_im_core PROJECT:Pods-1`
- `fleamarket://fish_coin_game?flutter=true&is_business_shop_game=true&showTask=true&channel=mainpage`
- `xianyu_flutter_ios`

Together these strongly indicate that the executable belongs to the Xianyu / 闲鱼 app family.

## Coin-game candidate names

Observed class names / symbol strings include:

- `FMCoinGameInterceptor`
- `FMCoinGameJumpUrlSwitch`
- `FMCoinGameOnceCompletion`
- `FishCoinPlugin`
- `FishCoinMethodPlugin`
- `HomeFishCoinEntranceView` (also seen as the Swift-mangled name `_TtC8IFMatrix24HomeFishCoinEntranceView`)
- `FishSyncJumpNewFishCoinEventObject`
- `AppIntentFishCoin`
- `WVFishCoin`

Related selector/property strings include:

- `interceptProcess:`
- `openFishCoinGameWithQuery:`
- `isCoinGameUrl:`
- `shouldInterceptCoinGame:`
- `getFishCoinUrl:`
- `setIdleCoinGame:`
- `gotoFishCoin`
- `fishCoinBidRegister`
- `fishcoin_method_channel`
- `fishcoin_event`

The class-name and method-name strings are useful search leads. Some may belong to Swift, Flutter bridge code, metadata, or code paths that are not active in the current app state. Confirm actual runtime registration and behavior with the reconnaissance dylib before designing hooks.

## Next validation steps

1. Inject the updated scout into the intended app process.
2. Confirm the load marker, bundle identifier, and version in the diagnostic log.
3. Review matching classes and the `+` / `-` method listings.
4. Keep the next iteration limited to discovery and logging until runtime results are understood.

No credentials, cookies, tokens, request bodies, or network captures are part of this inspection.
