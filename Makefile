export THEOS = /data/theos
export THEOS_MAKE_PATH = $(THEOS)/makefiles
export SDKVERSION = 16.5
export TARGET = iphone:clang:16.5:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TikTokNoWatermark

TikTokNoWatermark_FILES = source/Tweak.xm source/runtime.c
TikTokNoWatermark_CFLAGS = -fobjc-arc -Wno-error
TikTokNoWatermark_LDFLAGS = -framework AVFoundation -framework AVKit -framework Photos -framework UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@echo "Build complete: .theos/obj/$(TWEAK_NAME).dylib"
