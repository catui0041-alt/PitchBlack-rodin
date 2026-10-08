#
# Product configuration for PBRP on rodin.
#
# The recovery ramdisk contents are listed explicitly (the same approach the
# working community port for this board uses) instead of relying on implicit
# copying, because every file here has to end up inside vendor_boot.img.
#
DEVICE_PATH := device/xiaomi/rodin

# Virtual A/B with a vendor ramdisk — identical scheme to the stock ROM.
$(call inherit-product, $(SRC_TARGET_DIR)/product/virtual_ab_ota/launch_with_vendor_ramdisk.mk)

PRODUCT_USE_VIRTUAL_AB := true
PRODUCT_VIRTUAL_AB_OTA := true
PRODUCT_VIRTUAL_AB_COMPRESSION := true

PRODUCT_PROPERTY_OVERRIDES += \
    ro.product.device=rodin \
    ro.product.model=24129RT7CC \
    ro.product.brand=Redmi \
    ro.product.vendor.marketname=REDMI Turbo 4 \
    ro.board.platform=mt6899 \
    ro.boot.dynamic_partitions=true \
    ro.build.ab_update=true \
    ro.virtual_ab.enabled=true \
    ro.virtual_ab.userspace.snapshots.enabled=true \
    ro.virtual_ab.compression.enabled=true \
    ro.crypto.metadata_init_delete_all_keys.enabled=true \
    ro.crypto.volume.filenames_mode=aes-256-cts \
    ro.recovery.usb.vid=18D1 \
    ro.recovery.usb.adb.pid=D001 \
    ro.recovery.usb.fastboot.pid=4EE0

# Packages that exist in a plain PBRP/Android tree and are needed by a
# dynamic-partition, virtual-A/B recovery.
PRODUCT_PACKAGES += \
    bootctl \
    fastbootd \
    fsck.erofs \
    fsck.f2fs \
    lpdump \
    lpunpack \
    make_f2fs

PRODUCT_PACKAGES_DEBUG += \
    bootctrl \
    logcat

# Vendor-specific helpers. Uncomment only after confirming the module exists
# in the branch you build (they come from MediaTek/AOSP HAL repos, not from
# this device tree):
#
#   android.hardware.boot@1.2-mtkimpl
#   android.hardware.boot@1.2-mtkimpl.recovery
#   android.hardware.health@2.1-impl.recovery
#   snapuserd
#   snapuserd_ramdisk

# ------------------------------------------------------------------ ramdisk rc
RODIN_RECOVERY_ETC := $(DEVICE_PATH)/recovery/root/system/etc

PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/recovery/root/init.recovery.mt6899.rc:recovery/root/init.recovery.mt6899.rc \
    $(RODIN_RECOVERY_ETC)/recovery.fstab:recovery/root/system/etc/recovery.fstab \
    $(RODIN_RECOVERY_ETC)/twrp.flags:recovery/root/system/etc/twrp.flags

# first_stage_ramdisk fstab (used while the vendor ramdisk mounts partitions
# before the recovery UI starts).
ifneq ($(wildcard $(DEVICE_PATH)/recovery/root/first_stage_ramdisk/fstab.mt6899),)
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/recovery/root/first_stage_ramdisk/fstab.mt6899:recovery/root/first_stage_ramdisk/fstab.mt6899
endif

# ----------------------------------------------------- kernel modules (touch)
# Drop the recovery-only modules you extract from the ROM into
# prebuilt/modules/ and they are packaged automatically.
RODIN_MODULE_DIR := $(DEVICE_PATH)/prebuilt/modules
RODIN_MODULES := $(wildcard $(RODIN_MODULE_DIR)/*.ko)

ifneq ($(RODIN_MODULES),)
PRODUCT_COPY_FILES += $(foreach m,$(RODIN_MODULES),$(m):recovery/root/lib/modules/$(notdir $(m)))
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/recovery/root/system/bin/load-touch-modules.sh:recovery/root/system/bin/load-touch-modules.sh \
    $(DEVICE_PATH)/recovery/root/init.recovery.rodin-modules.rc:recovery/root/init.recovery.rodin-modules.rc
endif

# Haptics firmware/module for the vibration motor (optional, cosmetic).
ifneq ($(wildcard $(DEVICE_PATH)/prebuilt/haptics/si_haptic.ko),)
PRODUCT_COPY_FILES += \
    $(DEVICE_PATH)/prebuilt/haptics/si_haptic.ko:recovery/root/lib/modules/si_haptic.ko
endif

# ----------------------------------------------------- vendor blobs (TEE/FBE)
# The blob list lives in proprietary/vendor-blobs.mk and is only included when
# the files are actually present, so an incomplete tree still configures.
-include $(DEVICE_PATH)/proprietary/vendor-blobs.mk
