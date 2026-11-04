ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TikTok

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TikTokNoWatermark
TikTokNoWatermark_FILES = Tweak.xm
TikTokNoWatermark_FRAMEWORKS = Foundation UIKit Photos
# Logos preprocesses .xm into Objective-C++; Photos headers require C++11+.
TikTokNoWatermark_CFLAGS = -fobjc-arc -std=c++17 -Wno-deprecated-declarations -Wno-nullability-completeness

include $(THEOS_MAKE_PATH)/tweak.mk
