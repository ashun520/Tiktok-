export TARGET = iphone:clang:16.5:12.0
export ARCHS = arm64
export LOGOS_DEFAULT_GENERATOR = internal
export INSTALL_PATH = @executable_path

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = tiktokgod

tiktokgod_FILES = Tweak.xm runtime.c
tiktokgod_FRAMEWORKS = Photos AVKit
tiktokgod_CFLAGS = -fobjc-arc -fPIC -Wno-deprecated-declarations -Wno-nullability-completeness -Wno-unused-variable -Wno-undeclared-selector -Wno-unsupported-availability-guard
tiktokgod_LDFLAGS = --ld-path=/usr/bin/ld64.lld-18 -Xlinker -platform_version -Xlinker ios -Xlinker 12.0 -Xlinker 16.4 -install_name @executable_path/tiktokgod.dylib -dynamiclib -fPIE

include $(THEOS_MAKE_PATH)/tweak.mk
