TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

# Keep the normal feature tweak independent from diagnostic builds.
TWEAK_NAME := PiggyHandFish PiggyHandFishCapture PiggyHandFishProbe

PiggyHandFish_FILES := PFMain.m PFConfig.m PFLogger.m PFScout.m PFPluginEntry.m PFAction.m PFFishTaskRules.m
PiggyHandFish_CFLAGS := -fobjc-arc -Wall
PiggyHandFish_FRAMEWORKS := Foundation UIKit
PiggyHandFish_LDFLAGS := -install_name @rpath/PiggyHandFish.dylib

# Standalone runtime route capture module.
PiggyHandFishCapture_FILES := PFCapture.m
PiggyHandFishCapture_CFLAGS := -fobjc-arc -Wall
PiggyHandFishCapture_FRAMEWORKS := Foundation UIKit
PiggyHandFishCapture_LDFLAGS := -install_name @rpath/PiggyHandFishCapture.dylib

# Minimal diagnostic dylib: no router hooks or entry UI, only a constructor alert.
PiggyHandFishProbe_FILES := PFLoadProbe.m
PiggyHandFishProbe_CFLAGS := -fobjc-arc -Wall
PiggyHandFishProbe_FRAMEWORKS := Foundation UIKit
PiggyHandFishProbe_LDFLAGS := -install_name @rpath/PiggyHandFishProbe.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
