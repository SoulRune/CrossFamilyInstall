export THEOS_PACKAGE_SCHEME = rootless   # default; for a rootful .deb: make package THEOS_PACKAGE_SCHEME=

# IMPORTANT (unlike most UI tweaks such as AutoRotate): our target is installd,
# a SYSTEM DAEMON, not a regular App Store app. On A12+ devices, system
# processes (SpringBoard, daemons, Preferences) run as arm64e, not arm64. That
# means an arm64-only build (Linux/WSL toolchain) will NOT inject into installd
# on iPhone XS and newer - an arm64e slice is required, which only a macOS
# build (Xcode toolchain) provides. If you're on A11 or older (iPhone 8/X),
# an arm64-only build is sufficient.
ARCHS = arm64
# platform:compiler:sdk:deployment. iOS 14.0 minimum (per spec - 14+, not 15+).
TARGET = iphone:clang:latest:14.0
DEBUG = 0
FINALPACKAGE = 1
FOR_RELEASE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CrossFamilyInstall

CrossFamilyInstall_FILES = Tweak.xm
CrossFamilyInstall_CFLAGS = -fobjc-arc
CrossFamilyInstall_LIBRARIES = substrate
CrossFamilyInstall_PRIVATE_FRAMEWORKS = MobileInstallation CoreServices InstalledContentLibrary
CrossFamilyInstall_LDFLAGS = -Wl,-platform_version,ios,14.0,16.5

include $(THEOS_MAKE_PATH)/tweak.mk

# The preferences panel is built together with the tweak
SUBPROJECTS = CrossFamilyInstallPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
