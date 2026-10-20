TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES :=

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := PiggyHandFish
PiggyHandFish_FILES := Tweak.m PFConfig.m PFLogger.m PFScout.m PFPluginEntry.m PFAction.m
PiggyHandFish_CFLAGS := -fobjc-arc -Wall
PiggyHandFish_FRAMEWORKS := Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
