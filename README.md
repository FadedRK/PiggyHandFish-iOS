# PiggyHandFish-iOS

iOS runtime reconnaissance dylib for TrollFools on **iOS 17.0**.

This repository is an initial, reconnaissance-only project intended to help identify Objective-C runtime classes and methods in an app you are authorized to inspect. It does not automate account actions or collect credentials, cookies, tokens, request bodies, or network traffic.

## Current features

- Logs that the dylib was loaded, plus the target bundle identifier and app version.
- Enumerates Objective-C runtime classes matching a configurable regular expression.
- Optionally lists instance methods for matched classes.
- Writes diagnostics to the system log and to a temporary file named `piggyhandfish.log`.
- Includes conservative default limits to avoid excessively large logs.

## Requirements

- Theos toolchain with an iOS SDK
- TrollFools-compatible injection workflow
- Target device running iOS 17.0

## Build

From the repository root on a machine configured with Theos:

```sh
make clean package FINALPACKAGE=1
```

The package output is written to `.theos/packages/`. Review the build output and target app compatibility before installing anything on a device.

## Reconnaissance workflow

1. Build the dylib and inject it into an app you are authorized to inspect.
2. Confirm that the `PiggyHandFish` load marker appears in the system log.
3. Start with the default narrow class expression. Keep `logMethods` disabled initially.
4. Refine the class expression based on observed class names.
5. Enable method logging only for a narrow set of classes when needed.
6. Save and review the resulting diagnostic log before designing any app-specific adapter.

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
- The scout currently lists Objective-C runtime classes and **instance methods** only; it does not enumerate class methods or Swift-only symbols.
- `logStacks` is reserved for future work and is currently not used.
- Do not use this project to access other users' accounts, secrets, or private data.

## Project structure

- `Tweak.m` — dylib entry point
- `PFConfig.h/.m` — reconnaissance options
- `PFLogger.h/.m` — system and file logging
- `PFScout.h/.m` — runtime class and instance-method enumeration
- `Tweak.xm` — optional placeholder for future Logos work
- `config.example.json` — settings reference

## License

No license has been specified yet. Add a license before distributing or reusing this project.
