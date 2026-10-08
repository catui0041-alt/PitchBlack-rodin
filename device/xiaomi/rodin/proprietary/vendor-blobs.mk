#
# Vendor blobs that the recovery ramdisk needs on rodin.
#
# Every rule is guarded with $(wildcard ...): a blob that is not present in
# proprietary/ is silently skipped, so the tree configures and builds while you
# are still collecting files. The cost of a missing blob is a feature that does
# not work in recovery (usually FBE decryption or touch), never a build error.
#
# Source paths below are relative to device/xiaomi/rodin/proprietary/ and mirror
# the layout of the stock ROM (odm/, vendor/). Use
# tools/collect-blobs.sh to fill this directory from a firmware dump, or copy the
# files manually from vendor_ramdisk / odm / vendor.
#
# The list is the set of components a working community port for this exact
# board packages for FBE decryption and touch. Attribution: see
# docs/RODIN-NOTES.md.
#

RODIN_BLOB_PATHS := \
    vendor/bin/tee-supplicant \
    vendor/bin/hw/android.hardware.gatekeeper-service.mitee \
    vendor/bin/hw/android.hardware.security.keymint@3.0-service.mitee \
    vendor/bin/hw/android.hardware.weaver-service.nxp \
    vendor/bin/hw/vendor.xiaomi.hardware.secure_element-service \
    vendor/lib64/android.hardware.secure_element@1.0.so \
    vendor/lib64/android.hardware.secure_element@1.1.so \
    vendor/lib64/android.hardware.secure_element@1.2.so \
    vendor/lib64/android.hardware.secure_element-V1-ndk.so \
    vendor/lib64/android.hardware.weaver-V2-ndk.so \
    vendor/lib64/android.se.omapi-V1-ndk.so \
    vendor/lib64/libclang_rt.ubsan_standalone-aarch64-android.so \
    vendor/lib64/libmemunreachable.so \
    vendor/lib64/libmigpese@2.0.so \
    vendor/lib64/vendor.xiaomi.hardware.aidl.mtdservice-V1-ndk.so \
    vendor/etc/hal_uuid_map_rodin.xml \
    touch/lib64/android.frameworks.sensorservice-V1-ndk.so \
    touch/lib64/android.hardware.common-V2-ndk.so \
    touch/lib64/android.hardware.common.fmq-V1-ndk.so \
    touch/lib64/android.hardware.sensors-V2-ndk.so \
    touch/lib64/libc++.so \
    touch/lib64/libmisight.so \
    touch/lib64/vendor.xiaomi.hw.touchfeature-V1-ndk.so

# 1:1 copies (blob keeps its relative path inside the recovery ramdisk).
PRODUCT_COPY_FILES += $(foreach f,$(RODIN_BLOB_PATHS),\
    $(if $(wildcard $(DEVICE_PATH)/proprietary/$(f)),$(DEVICE_PATH)/proprietary/$(f):recovery/root/$(f)))

# Blobs whose ramdisk location differs from their ROM location.
#
# The odm/ blobs are here rather than in RODIN_BLOB_PATHS on purpose. AOSP's
# system/core/rootdir fills the ramdisk root with symlinks before the recovery
# root is assembled:
#
#     odm/bin      -> /vendor/odm/bin      odm/firmware -> /vendor/odm/firmware
#     odm/lib64    -> /vendor/odm/lib64    (etc/, app/, framework/, lib/, usr/)
#     bin -> /system/bin   etc -> /system/etc   cache -> /data/cache
#
# The assembly then rsyncs that root tree over recovery/root with -a, so a real
# directory at one of those destinations cannot be replaced by the symlink:
# "could not make way for new symlink: root/odm/bin" / "cannot delete non-empty
# directory", and the build dies at 99% in ramdisk_files-timestamp. Files for
# the odm partition therefore go to system/ (visible at runtime whatever the
# odm mount does), never to recovery/root/odm/**.
RODIN_BLOB_REMAP := \
    odm/bin/hw/vendor.xiaomi.hw.touchfeature-service-recovery:recovery/root/system/bin/vendor.xiaomi.hw.touchfeature-service-recovery \
    odm/lib64/libtensorflowlite_touch_c.so:recovery/root/system/lib64/rodin-touch/libtensorflowlite_touch_c.so \
    odm/firmware/rodin_gtp_thp_config.ini:recovery/root/system/etc/rodin-touch/rodin_gtp_thp_config.ini \
    odm/firmware/rodin_gtp_thp_config_vendor.ini:recovery/root/system/etc/rodin-touch/rodin_gtp_thp_config_vendor.ini \
    vendor/lib64/ese_weaver.nxp.so:recovery/root/system/lib64/ese_weaver.nxp.so \
    vendor/lib64/libjc_keymint_transport.nxp.so:recovery/root/system/lib64/libjc_keymint_transport.nxp.so \
    vendor/lib64/libteecli.so:recovery/root/system/lib64/libteecli.so \
    odm/lib64/libtouchreport.so:recovery/root/system/lib64/rodin-touch/libtouchreport.so \
    odm/lib64/libtouchreport_alg_goodix.so:recovery/root/system/lib64/rodin-touch/libtouchreport_alg_goodix.so \
    odm/lib64/libtouchreport_alg_fts.so:recovery/root/system/lib64/rodin-touch/libtouchreport_alg_fts.so \
    odm/lib64/libtouchreport_hal.so:recovery/root/system/lib64/rodin-touch/libtouchreport_hal.so \
    odm/lib64/libtouchreport_sensor.so:recovery/root/system/lib64/rodin-touch/libtouchreport_sensor.so \
    vendor/etc/vintf/manifest/android.hardware.gatekeeper-service.mitee.xml:recovery/root/vendor/etc/vintf/manifest/android.hardware.gatekeeper-service.mitee.xml \
    vendor/etc/vintf/manifest/android.hardware.security.keymint-service.mitee.xml:recovery/root/vendor/etc/vintf/manifest/android.hardware.security.keymint-service.mitee.xml \
    vendor/etc/vintf/manifest/android.hardware.security.secureclock-service.mitee.xml:recovery/root/vendor/etc/vintf/manifest/android.hardware.security.secureclock-service.mitee.xml \
    vendor/etc/vintf/manifest/android.hardware.security.sharedsecret-service.mitee.xml:recovery/root/vendor/etc/vintf/manifest/android.hardware.security.sharedsecret-service.mitee.xml \
    vendor/etc/vintf/manifest/android.hardware.weaver-service.nxp.xml:recovery/root/vendor/etc/vintf/manifest/android.hardware.weaver-service.nxp.xml

PRODUCT_COPY_FILES += $(foreach r,$(RODIN_BLOB_REMAP),\
    $(if $(wildcard $(DEVICE_PATH)/proprietary/$(firstword $(subst :, ,$(r)))),\
    $(DEVICE_PATH)/proprietary/$(firstword $(subst :, ,$(r))):$(lastword $(subst :, ,$(r)))))

# The TEE trusted applications are a directory of .ta files. A directory must
# never appear as a source in PRODUCT_COPY_FILES: the generated copy rule runs
# "rm -f <dest>" first, and rm refuses to unlink a directory, so the build dies
# with "rm: <dest>: Is a directory". Expand the directory into one rule per file
# instead. This is also why the .ta files stay out of RODIN_BLOB_PATHS.
RODIN_MITEE_TA_DIR := $(DEVICE_PATH)/proprietary/vendor/mitee/ta
RODIN_MITEE_TAS := $(wildcard $(RODIN_MITEE_TA_DIR)/*.ta)
PRODUCT_COPY_FILES += $(foreach t,$(RODIN_MITEE_TAS),$(t):recovery/root/vendor/mitee/ta/$(notdir $(t)))
