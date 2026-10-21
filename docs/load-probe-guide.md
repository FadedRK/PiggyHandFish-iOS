# PiggyHandFish Load Probe

This is the first-stage diagnostic build. It deliberately does not hook Xianyu routes, scan classes, or install the capture overlay.

## Test

1. Disable/remove the previous PiggyHandFish and PiggyHandFish-Capture builds in TrollFools for this test, so that only `PiggyHandFish-LoadProbe.dylib` is injected into `com.taobao.fleamarket`.
2. Force-quit Xianyu, then launch it again.
3. Look for a native alert titled **PiggyHandFish Load Probe**. It should say that the dylib constructor executed and show the app bundle/version.
4. After confirming the popup, tap `确定`, force-quit Xianyu again, remove/disable the probe, then install `PiggyHandFish-Capture.dylib` for route capture.

## Interpretation

- Popup shown: the dylib was loaded and its constructor code executed inside the Xianyu process. The earlier missing entry must be investigated in the UI/route layer next.
- No popup shown: this does not by itself prove the file was not injected. Next inspect the app's crash/device log and TrollFools injection settings; the probe also writes `piggyhandfish-load-probe.log` under the app's temporary directory if its constructor reaches the logging code.

The probe only displays the diagnostic alert and writes local diagnostic logs. It does not inspect or modify account data.
