# PiggyHandFish-iOS

iOS runtime reconnaissance dylib for TrollFools on **iOS 17.0**.

This repository is an initial, reconnaissance-only project intended to identify Objective-C runtime classes and methods in an app you are authorized to inspect. It does not automate account actions or collect credentials, cookies, tokens, request bodies, or network traffic.

## Current features

- Logs the dylib load marker, target bundle identifier, app version, and build.
- Enumerates Objective-C runtime classes matching a configurable regular expression.
- Optionally lists instance methods and class methods for matched classes.
- Filters method names to reduce log volume.
- Writes diagnostics to the system log and to a temporary file named `piggyhandfish.log`.

## Target and initial findings

The supplied local executable named `Runner` was inspected statically. It is a 64-bit ARM64 Mach-O executable. Strings and symbols include Xianyu identifiers such as `com.taobao.fleamarket`, `idlefish_im_core`, and the route `fleamarket://fish_coin_game`.

Coin-game-related candidate names found in the executable include:

- `FMCoinGameInterceptor`, with selector strings `interceptProcess:` and `openFishCoinGameWithQuery:`
- `FMCoinGameJumpUrlSwitch` and `FMCoinGameOnceCompletion`
- `FishCoinPlugin` and `FishCoinMethodPlugin`
- `HomeFishCoinEntranceView`
- `FishSyncJumpNewFishCoinEventObject`
- `AppIntentFishCoin` and `WVFishCoin`

These are static-analysis leads, not proof that every candidate is registered in the runtime or that a particular call sequence has been confirmed. The executable itself is not stored in this repository.

## Requirements

- Theos toolchain with an iOS SDK
- TrollFools-compatible injection workflow
- Target device running iOS 17.0

## Build

From the repository root on a machine configured with Theos:

```sh
make clean package FINALPACKAGE=1
```

The package output is written to `.theos/packages/`. This code has not yet been confirmed as successfully compiled or tested on-device.

## Reconnaissance workflow

1. Build the dylib and inject it into the app you are authorized to inspect.
2. Confirm that the `PiggyHandFish` load marker appears in the system log.
3. Review the filtered class, instance-method, and class-method results.
4. Narrow the class and method expressions based on the actual runtime output.
5. Save the diagnostic log before designing any app-specific adapter.

The initial configuration is compiled in `PFConfig.m`; `config.example.json` documents the available settings. JSON runtime loading is not implemented yet.

## Log location

The diagnostic file is written to:

```
NSTemporaryDirectory()/piggyhandfish.log
```

On iOS this usually resolves inside the target app's temporary container. System log output is also available through your usual device logging tools.

## Scope and limitations

- This is not yet an implementation of the Android LSPosed module's features.
- Android Java/Xposed classes do not map directly to iOS Objective-C runtime classes.
- Runtime introspection does not enumerate Swift-only symbols or prove that a discovered method is safe to invoke.
- `logStacks` is reserved for future work and is currently not used.
- Do not use this project to access other users' accounts, secrets, or private data.

## Project structure

- `Tweak.m` — dylib entry point
- `PFConfig.h/.m` — reconnaissance options
- `PFLogger.h/.m` — system and file logging
- `PFScout.h/.m` — runtime class and method enumeration
- `Tweak.xm` — optional placeholder for future Logos work
- `config.example.json` — settings reference

## License

No license has been specified yet. Add a license before distributing or reusing this project.
