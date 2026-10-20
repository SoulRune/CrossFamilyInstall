# Subprojects run their own make pass and don't inherit settings from the
# main Makefile - arch/target/linker flags are duplicated here.
ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CrossFamilyInstallPrefs

CrossFamilyInstallPrefs_FILES = RootListController.mm \
    CFISpoofStore.m CFISpoofListBase.m \
    CFIAppsTableController.m CFIAppSpoofController.m \
    CFIBulkSpoofController.m CFISpoofPresets.m
CrossFamilyInstallPrefs_INSTALL_PATH = /Library/PreferenceBundles
CrossFamilyInstallPrefs_FRAMEWORKS = UIKit CoreGraphics
CrossFamilyInstallPrefs_PRIVATE_FRAMEWORKS = Preferences
CrossFamilyInstallPrefs_CFLAGS = -fobjc-arc
CrossFamilyInstallPrefs_LDFLAGS = -Wl,-platform_version,ios,14.0,16.5

include $(THEOS_MAKE_PATH)/bundle.mk
