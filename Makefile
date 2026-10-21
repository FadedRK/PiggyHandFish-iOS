TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

# Keep the normal feature tweak independent from the diagnostic capture tweak.
TWEAK_NAME := PiggyHandFish PiggyHandFishCapture

PiggyHandFish_FILES := PFMain.m PFConfig.m PFLogger.m PFScout.m PFPluginEntry.m PFAction.m
PiggyHandFish_CFLAGS := -fobjc-arc -Wall
PiggyHandFish_FRAMEWORKS := Foundation UIKit
PiggyHandFish_LDFLAGS := -install_name @rpath/PiggyHandFish.dylib

# Standalone capture-only dylib: it does not compile PFMain.m or the old entry hooks.
PiggyHandFishCapture_FILES := PFCapture.m
PiggyHandFishCapture_CFLAGS := -fobjc-arc -Wall
PiggyHandFishCapture_FRAMEWORKS := Foundation UIKit
PiggyHandFishCapture_LDFLAGS := -install_name @rpath/PiggyHandFishCapture.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
