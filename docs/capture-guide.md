# PiggyHandFish Capture Build

This build is for collecting runtime evidence before adding a permanent plugin entry.

## Install and capture

1. Import `PiggyHandFish-Capture.dylib` into TrollFools for the Xianyu app (`com.taobao.fleamarket`).
2. Fully force-close Xianyu and launch it again.
3. Look for the red **抓取** bubble near the top-right of the screen. It is installed independently of the Xianyu Settings page.
4. Reproduce the navigation that should expose the plugin entry. Open Xianyu Settings, enter/leave the suspected Flutter Settings page, and repeat the action once or twice.
5. Tap **抓取** → **导出抓取日志**, then attach the exported `piggyhandfish-capture.log` in the conversation.

The log includes a constructor load marker, the app bundle/version, whether target Objective-C route hooks were installed, router method encodings, selected runtime class/method inventory, and route/Flutter-channel events.

## Privacy

The capture module does not log cookies, authentication headers, passwords, tokens, or complete arbitrary message payloads. URL query strings and fragments are stripped before route strings are logged. The capture file is in the app's temporary directory and can be exported from the floating capture control.

## Interpreting the result

- No **抓取** bubble: the constructor or UIKit overlay did not execute; treat this as a load/injection question, not a route-matching question.
- Bubble appears but no `HOOK_OK` for `FMURLRouter`: compare `RUNTIME_CLASS` and `RUNTIME_METHOD` records against the methods present in this app build.
- Hooks are installed but no route events occur: inspect the Flutter channel records and the exact user action sequence.
