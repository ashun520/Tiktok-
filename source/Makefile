export TARGET = iphone:clang:16.5:12.0
export ARCHS = arm64
# internal generator = pure ObjC runtime swizzling, no CydiaSubstrate dependency
export LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = tiktokgod

tiktokgod_FILES = Tweak.xm runtime.c
tiktokgod_FRAMEWORKS = Photos
tiktokgod_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness -Wno-unused-variable
tiktokgod_LDFLAGS = --ld-path=/usr/bin/ld64.lld-18 -Xlinker -platform_version -Xlinker ios -Xlinker 12.0 -Xlinker 16.4

include $(THEOS_MAKE_PATH)/tweak.mk
