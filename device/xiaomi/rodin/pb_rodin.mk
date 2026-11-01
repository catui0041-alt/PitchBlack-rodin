#
# PBRP product for rodin.
# Order follows the pb_device.mk sample in PBRP's manifest:
# core product files first, then the device, then PBRP's common config.
#
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)
$(call inherit-product, device/xiaomi/rodin/device.mk)
$(call inherit-product, vendor/pb/config/common.mk)

PRODUCT_DEVICE := rodin
PRODUCT_NAME := pb_rodin
PRODUCT_BRAND := Redmi
PRODUCT_MODEL := 24129RT7CC
PRODUCT_MANUFACTURER := Xiaomi
PRODUCT_RELEASE_NAME := Redmi Turbo 4
PRODUCT_GMS_CLIENTID_BASE := android-xiaomi

# The stock ROM reports Android 15/16. The recovery build system may expose a
# lower SystemSDK; keep the shipping level at the API the branch supports and
# raise it only if the branch allows it.
PRODUCT_SHIPPING_API_LEVEL := 34

# The recovery has to describe the firmware the device actually runs. This
# tree is built against the global OS3.0.302.0.WOJMIXM dump: its prebuilt
# platform ramdisk, DTB and vbmeta chain are that revision (see
# prebuilt/README.md). The product fingerprint used to name the Chinese
# OS3.0.303.0.WOJCNXM revision, which put a foreign region token into every
# image; it now matches the dump the prebuilts come from.
BUILD_FINGERPRINT := POCO/rodin_global/rodin:15/AP3A.240905.015.A2/OS3.0.302.0.WOJMIXM:user/release-keys
PRIVATE_BUILD_DESC := rodin_global-user 15 AP3A.240905.015.A2 OS3.0.302.0.WOJMIXM release-keys

PRODUCT_BUILD_PROP_OVERRIDES += \
    TARGET_DEVICE=rodin \
    PRODUCT_NAME=rodin \
    PRIVATE_BUILD_DESC="$(PRIVATE_BUILD_DESC)"
