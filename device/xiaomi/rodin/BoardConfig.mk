#
# PitchBlack Recovery Project (PBRP) — board configuration
# Device: POCO X7 Pro / Redmi Turbo 4 (rodin), MediaTek MT6899
#
# Every numeric value below was read from the device's own stock firmware
# images (boot.img / vendor_boot.img / super.img layout) and cross-checked
# against the public LineageOS rodin device tree.
# See docs/RODIN-NOTES.md for the provenance of each group of values.
#
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/xiaomi/rodin

# ------------------------------------------------------------------- Platform
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := cortex-a55
TARGET_CPU_VARIANT_RUNTIME := cortex-a55

# Recovery is built with a 32-bit secondary ABI because several vendor
# libraries shipped in the ramdisk are 32/64-bit hybrids.
TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a55

TARGET_BOARD_PLATFORM := mt6899
TARGET_BOOTLOADER_BOARD_NAME := mt6899
TARGET_NO_BOOTLOADER := true
TARGET_NO_RADIOIMAGE := true
TARGET_USES_UEFI := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true

# ------------------------------------------------------------------ Recovery
# rodin does not boot a standalone recovery.img: the recovery ramdisk is
# delivered inside the vendor_boot image (see docs/RODIN-NOTES.md).
TARGET_NO_RECOVERY := true
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery/root/system/etc/recovery.fstab
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USERIMAGES_USE_EROFS := true

# --------------------------------------------------------------------- Kernel
# GKI device: the kernel stays in boot.img and is not duplicated in recovery.
TARGET_NO_KERNEL := true
BOARD_USES_GENERIC_KERNEL_IMAGE := true
BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE := true
BOARD_RAMDISK_USE_LZ4 := true

TARGET_KERNEL_ARCH := arm64
TARGET_KERNEL_HEADER_ARCH := arm64

# Boot image geometry, taken from the stock header (header version 4,
# page size 4096, the offsets below are the MTK physical load addresses).
BOARD_BOOT_HEADER_VERSION := 4
BOARD_KERNEL_BASE := 0x3fff8000
BOARD_KERNEL_PAGESIZE := 4096
BOARD_PAGE_SIZE := 4096
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_RAMDISK_OFFSET := 0x26f08000
BOARD_KERNEL_TAGS_OFFSET := 0x07c88000
BOARD_DTB_OFFSET := 0x07c88000
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2 erofs.reserved_pages=64

# mkbootimg defaults do not match the stock load addresses; keep them explicit
# so the MTK bootloader accepts the generated image.
BOARD_MKBOOTIMG_ARGS += \
--header_version $(BOARD_BOOT_HEADER_VERSION) \
--kernel_offset $(BOARD_KERNEL_OFFSET) \
--ramdisk_offset $(BOARD_RAMDISK_OFFSET) \
--tags_offset $(BOARD_KERNEL_TAGS_OFFSET) \
--dtb_offset $(BOARD_DTB_OFFSET)

# The DTB that matches this board lives in prebuilt/dtb (extracted from the
# stock vendor_boot by tools/extract-prebuilts.sh).
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := $(DEVICE_PATH)/prebuilt/dtb

# ------------------------------------------------------ Recovery in vendor_boot
BOARD_USES_RECOVERY_AS_BOOT := false
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_MOVE_GSI_AVB_KEYS_TO_VENDOR_BOOT := true

# ----------------------------------------------------------------- Partitions
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_INIT_BOOT_IMAGE_PARTITION_SIZE := 8388608
BOARD_DTBOIMG_PARTITION_SIZE := 8388608
BOARD_FLASH_BLOCK_SIZE := 131072
BOARD_HAS_LARGE_FILESYSTEM := true

BOARD_SUPER_PARTITION_SIZE := 9125756928
BOARD_SUPER_PARTITION_BLOCK_DEVICES := super
BOARD_SUPER_PARTITION_METADATA_DEVICE := super
BOARD_SUPER_PARTITION_SUPER_DEVICE_SIZE := 9125756928
BOARD_SUPER_PARTITION_GROUPS := mediatek_dynamic_partitions
BOARD_MEDIATEK_DYNAMIC_PARTITIONS_SIZE := 9121562624
BOARD_MEDIATEK_DYNAMIC_PARTITIONS_PARTITION_LIST := \
odm \
odm_dlkm \
product \
system \
system_dlkm \
system_ext \
vendor \
vendor_dlkm

BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_ODM_DLKMIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_DLKMIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_VENDOR_DLKMIMAGE_FILE_SYSTEM_TYPE := erofs

TARGET_COPY_OUT_ODM := odm
TARGET_COPY_OUT_ODM_DLKM := odm_dlkm
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_SYSTEM_DLKM := system_dlkm
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_VENDOR_DLKM := vendor_dlkm

# Virtual A/B
AB_OTA_UPDATER := true
PRODUCT_USE_DYNAMIC_PARTITIONS := true
BOARD_USES_METADATA_PARTITION := true
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs
BOARD_METADATAIMAGE_FILE_SYSTEM_TYPE := f2fs
AB_OTA_PARTITIONS += \
boot \
dtbo \
init_boot \
mi_ext \
odm \
odm_dlkm \
product \
system \
system_dlkm \
system_ext \
vbmeta \
vbmeta_system \
vbmeta_vendor \
vendor \
vendor_boot \
vendor_dlkm

# ----------------------------------------------------------------------- AVB
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
BOARD_AVB_ALGORITHM := SHA256_RSA4096
BOARD_AVB_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem

# ------------------------------------------------------------------ PBRP/TWRP
TW_THEME := portrait_hdpi
TARGET_SCREEN_WIDTH := 1220
TARGET_SCREEN_HEIGHT := 2712
TW_MAX_BRIGHTNESS := 2047
TW_DEFAULT_BRIGHTNESS := 1000
TW_DEFAULT_LANGUAGE := ar

# Battery, storage and USB behaviour proven on this board.
TW_USE_LEGACY_BATTERY_SERVICES := true
TW_INCLUDE_FASTBOOTD := true
TW_INCLUDE_LPTOOLS := true
TW_INCLUDE_REPACKTOOLS := true
TW_INCLUDE_RESETPROP := true
TW_INCLUDE_EROFS := true
TW_EXCLUDE_APEX := true
TW_HAS_MTP := true
TW_MTP_DEVICE := /dev/mtp_usb
TW_NO_USB_STORAGE := true
TW_EXCLUDE_DEFAULT_USB_INIT := true
TW_INPUT_BLACKLIST := "hbtp_vm"
RECOVERY_SDCARD_ON_DATA := true
TARGET_RECOVERY_DEVICE_MODULES += libtrusty

TW_INCLUDE_CRYPTO := true
TW_INCLUDE_FBE := true
TW_INCLUDE_FBE_METADATA_DECRYPT := true
TW_USE_FSCRYPT_POLICY := 2

TARGET_USES_LOGD := true
TWRP_INCLUDE_LOGCAT := true

# Uncomment once the first build boots and the panel survives screen blanking.
# TW_DRM_BLANK_KEEP_PIPELINE := true

PRODUCT_SOONG_NAMESPACES += $(DEVICE_PATH)

# Blob set (KeyMint / Weaver / touch / haptics) extracted from the stock ROM.
# The tree still configures without it, the recovery is just incomplete.
-include $(DEVICE_PATH)/proprietary/BoardConfigVendor.mk
