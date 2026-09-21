TARGET = iphone:clang:5.1:3.0
ARCHS = armv6 armv7
THEOS = /home/spytaspund/ios-devel/theos

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

THEOS_DEVICE_IP = 192.168.50.101
THEOS_DEVICE_PORT = 22
SSH_USER ?= root
SSH_PASS ?= alpine

SSH = ssh -o HostKeyAlgorithms=+ssh-rsa -p $(THEOS_DEVICE_PORT) $(SSH_USER)@$(THEOS_DEVICE_IP)
SCP = scp -o HostKeyAlgorithms=+ssh-rsa -P $(THEOS_DEVICE_PORT)

deploy: package
	@$(eval DEB_EXACT_PATH := $(shell ls -t ./packages/*.deb 2>/dev/null | head -n 1))
	@$(eval DEB_NAME := $(notdir $(DEB_EXACT_PATH)))
	@if [ -z "$(DEB_EXACT_PATH)" ]; then echo "==> Error: .deb not found!"; exit 1; fi
	@echo "==> Found $(DEB_NAME)"
	@echo "==> Copying $(DEB_NAME) to the device..."
	$(SCP) "$(DEB_EXACT_PATH)" $(SSH_USER)@$(THEOS_DEVICE_IP):/tmp/
	@echo "==> Installing $(DEB_NAME)..."
	$(SSH) "dpkg -i /tmp/$(DEB_NAME)"

respring:
	$(SSH) "killall -9 SpringBoard"

logs:
	$(SSH) "tail -f /var/log/syslog | grep RedAlien"

after-install::
	install.exec "killall -9 SpringBoard"

.PHONY: deploy respring logs package