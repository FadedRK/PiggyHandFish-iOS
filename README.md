# PiggyHandFish-iOS

iOS runtime reconnaissance dylib for TrollFools on **iOS 17.0**.

This repository is an initial, reconnaissance-only project intended to identify Objective-C runtime classes and methods in an app you are authorized to inspect. It does not automate account actions or collect credentials, cookies, tokens, request bodies, or network traffic.

## Current features

- Logs the dylib load marker, target bundle identifier, app version, and build.
- Adds a floating **“猪手” plugin entry** to the host app window.
- Opens a control panel with a registered native Action list and session-only reconnaissance settings.
- Enumerates Objective-C runtime classes matching a configurable regular expression.
- Optionally lists instance methods and class methods for matched classes.
- Filters method names to reduce log volume.
- Writes diagnostics to the system log and to a temporary file named `piggyhandfish.log`.

## Plugin entry

After injection, look for the floating orange **猪手** button near the lower-right side of the app. Tap it to open the panel.

Available controls:

- **立即运行侦察** — run the current runtime scan again.
- **类名日志 / 实例方法日志 / 类方法日志** — turn individual log categories on or off for this process session.
- **查看运行状态** — view bundle/version, filters, toggles, and log path.
- **复制诊断日志 / 复制日志文件路径** — copy diagnostic text or the file path to the clipboard.

The logging toggles currently affect the running process only; they are not persisted after the app exits. The entry is installed when a foreground app window becomes available. If no active window appears, installation is retried for a short period and again when the app becomes active.

## Native Action registry

The menu is populated by PFRegisteredActions() in PFAction.m. Current Actions:

- 打开闲鱼鱼币任务页 — opens the Xianyu deep link found in the supplied binary; the user continues manually inside the app.
- 运行 Runtime 侦察 — performs a filtered Objective-C runtime scan on a background queue.
- 复制诊断日志 — copies the newest diagnostics to the clipboard.
- 清空诊断日志 — clears this plugin's temporary log file.
- 记录运行状态 — writes the app bundle and version to the diagnostic log.

The Android task engine has not been ported wholesale. This native Action layer does not perform protocol-request substitution, silent task triggering, or automated reward claiming.

## Target and initial findings

The supplied local executable named `Runner` was inspected statically. It is a 64-bit ARM64 Mach-O executable. Strings and symbols include Xianyu identifiers such as `com.taobao.fleamarket`, `idlefish_im_core`, and the route `fleamarket://fish_coin_game`.

Coin-game-related candidate names found in the executable include:

- `FMCoinGameInterceptor`, with selector strings `interceptProcess:` and `openFishCoinGameWithQuery:`
- `FMCoinGameJumpUrlSwitch` and `FMCoinGameOnceCompletion`
- `FishCoinPlugin` and `FishCoinMethodPlugin`
- `HomeFishCoinEntranceView`
- `FishSyncJumpNewFishCoinEventObject`
- `AppIntentFishCoin` and `WVFishCoin`

These are static-analysis leads, not proof that every class is registered in the runtime or that a particular call sequence has been confirmed. The executable itself is not stored in this repository.

## Requirements

- Theos toolchain with an iOS SDK
- TrollFools-compatible injection workflow
- Target device running iOS 17.0

## Build

From the repository root on a machine configured with Theos:

```sh
make clean && make
```

The dylib is written under `.theos/obj/`. This code has not yet been confirmed as successfully compiled or tested on-device.

## CI build artifact

Every push to main starts the **Build iOS dylib** GitHub Actions workflow. Open the [Actions page](https://github.com/FadedRK/PiggyHandFish-iOS/actions), select a successful run, and download the generated artifact. A failed run does not produce a usable dylib.

## Reconnaissance workflow

1. Build the dylib and inject it into the app you are authorized to inspect.
2. Confirm that the `PiggyHandFish` load marker appears in the system log.
3. Tap the floating entry and use **立即运行侦察** to repeat a scan.
4. Enable only the log categories needed for the next scan.
5. Export the diagnostic log from the panel and review the results.
6. Narrow the class and method expressions based on the actual runtime output.

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
- `PFPluginEntry.h/.m` — floating plugin button and control panel
- `PFConfig.h/.m` — reconnaissance options
- `PFLogger.h/.m` — system and file logging
- `PFScout.h/.m` — runtime class and method enumeration
- `Tweak.xm` — optional placeholder for future Logos work
- `config.example.json` — settings reference

## License

No license has been specified yet. Add a license before distributing or reusing this project.
