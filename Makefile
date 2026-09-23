TARGET = iphone:clang:5.1:3.0
ARCHS = armv6 armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedAlien
RedAlien_FILES = Tweak.x Auth.m RAProtocol.m Video.m SubIcon.m Gallery.m HTTPServer.m LoginVC.m JSONKit.m MockResponse.m
RedAlien_FRAMEWORKS = UIKit

RedAlien_CFLAGS = -std=gnu99 -D_DARWIN_C_SOURCE -D_GNU_SOURCE \
                  -Wno-ignored-attributes -w \
                  -fno-exceptions -fno-rtti \
                  -fno-unwind-tables -fno-asynchronous-unwind-tables \
                  -mno-unaligned-access \
                  -marm -march=armv6 -mcpu=arm1176jzf-s \
                  -Wno-ignored-optimization-argument -Wno-unknown-argument

RedAlien_CXXFLAGS = $(RedAlien_CFLAGS)
RedAlien_LDFLAGS = -lSystem

include $(THEOS_MAKE_PATH)/tweak.mk

THEOS_DEVICE_PORT ?= 22

.PHONY: after-install