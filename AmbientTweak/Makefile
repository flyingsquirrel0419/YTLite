DEBUG=0
FINALPACKAGE=1
ARCHS = arm64
PACKAGE_VERSION = 1.0.0
TARGET := iphone:clang:16.5:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTLiteAmbient
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreImage QuartzCore
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FILES = Ambient.x Utils/YTLUserDefaults.m

include $(THEOS_MAKE_PATH)/tweak.mk
