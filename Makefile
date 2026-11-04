ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = TikTok

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TikTokNoWatermark
TikTokNoWatermark_FILES = Tweak.xm
TikTokNoWatermark_FRAMEWORKS = Foundation UIKit Photos
TikTokNoWatermark_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness

include $(THEOS_MAKE_PATH)/tweak.mk
