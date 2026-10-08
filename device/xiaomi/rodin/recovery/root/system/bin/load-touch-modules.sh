#!/system/bin/sh
# Loads the recovery-only kernel modules for rodin.
# These modules are needed for the touchscreen and the haptic motor to work
# inside recovery; the display and storage modules come from the stock vendor
# ramdisk that is packed into vendor_boot.
#
# Module order matters: the vendor touch driver must be loaded before the
# per-panel driver.
MODDIR=/lib/modules

load() {
    if [ -f "${MODDIR}/$1.ko" ]; then
        insmod "${MODDIR}/$1.ko" 2>/dev/null
    fi
}

for mod in scp xiaomi_touch_rodin focaltech_touch_rodin goodix_core_rodin si_haptic; do
    load "${mod}"
done

exit 0
