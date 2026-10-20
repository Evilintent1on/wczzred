ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = wczzred
wczzred_FILES = Tweak.xm
wczzred_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DPACKAGE_VERSION=@\"$(shell grep '^Version:' control | cut -d' ' -f2)\"
wczzred_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
