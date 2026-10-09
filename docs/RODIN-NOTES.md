# ملاحظات rodin التقنية

كل رقم في هذا الملف **مقيس من دامب الفلاشة الموجود على جهازك**، لا منقول من
مصدر عام، ما لم يُذكر خلاف ذلك.

## قياسات الصور الأصلية

| الصورة | النوع | القياس المؤكد |
|---|---|---|
| `boot.img` | ANDROID! header v4 | page=4096، kernel=17,184,688 بايت، ramdisk=0 |
| `init_boot.img` | ANDROID! header v4 | kernel=0، ramdisk=2,479,854 بايت |
| `vendor_boot.img` | VNDRBOOT header v4 | ramdisk section=43,376,500 / dtb=444,841 / table=216 / vbmeta=704 |
| `recovery.img` (stock) | ANDROID! header v4 | kernel=**0**، ramdisk=24,558,346 |

تفصيل vendor_boot:

```
0x000     header v4 (2128 بايت) — cmdline: bootopt=64S3,32N2,64N2
0x1000    [0] platform ramdisk  29,231,353 بايت  lz4 legacy (02 21 4c 18)
0x1BE08F9 [1] recovery ramdisk  14,145,147 بايت  lz4 legacy
0x295F000 DTB region: 64 بايت حاوية MTK (d7 b7 ab 1e + الحجم 0x6C9A9)
0x295F040 FDT الحقيقي: 444,841 بايت (d0 0d fe ed)
0x29CC000 جدول ramdisks: 2 مدخلات × 108 بايت
0x29CD000 vbmeta مدمج: "AVB0" بحجم 704 بايت
...       توقيع AVB footer في آخر القسم ("AVBf")
67,108,864 = حجم قسم vendor_boot بالبايت
```

ملاحظات مهمة مستخلصة:

1. **الاسترجاع لا يحمل كيرنل**: صورة الاسترجاع الأصلية `kernel_size=0`. لذلك
   `TARGET_NO_KERNEL := true` و`BOARD_EXCLUDE_KERNEL_FROM_RECOVERY_IMAGE := true`.
2. **الـ platform ramdisk ضروري**: يحتوي first-stage init وتعريفات التخزين
   والشاشة التي تستخدمها جزئية الـ recovery عند الإقلاع. لا يُعاد بناؤه من
   المصدر في شجرتنا؛ يُنسخ كما هو من الصورة الأصلية.
3. **الـ DTB بحاوية MTK 64 بايت**: أداة `extract-prebuilts.sh` تكتشفها تلقائياً
   وتصدّر FDT المجرّد (وهو ما يتوقعه `BOARD_PREBUILT_DTBIMAGE_DIR`) مع نسخة من
   الحاوية كمرجع.
4. **AVB مدمج**: الصورة الأصلية فيها vbmeta داخلي (704 بايت). أي تغيير في
   أحجام الـ ramdisks يُبطِل هذا التوقيع، ولذلك يُعيد `make-vendor-boot.sh`
   التوقيع بـ avbtool بمفتاح AOSP التجريبي.

## استرجاع المصنع كمرجع (مقروء من جهازك)

بعد فكّ الـ platform ramdisk و ramdisk الـ recovery بـ `tools/vendor_ramdisk.py`
(14,145,147 بايت) تبين التالي، وكلّه مُطبَّق في شجرتنا:

* `init.recovery.mt6899.rc` الأصلي (356 بايت) يضبط:
  `sys.usb.configfs 1` و`sys.usb.controller "11201000.usb0"` — بدونها لا يعمل
  adb/fastbootd في الاسترجاع. نسخنا القيم حرفياً.
* `init.recovery.hardware.rc` **فارغ (0 بايت)** — موجود فقط ليرضى init.
* جدول first-stage اسمه `first_stage_ramdisk/fstab.emmc`، ونحن نبني
  `fstab.mt6899` أيضاً (الملف نفسه باسمين) تحوطاً لاختلاف `ro.hardware`.
* `system/etc/recovery.fstab` الأصلي فيه **91 نقطة تحميل**؛ كان عندي 31.
  أضفت 37 قسم فروموير (modem, tee1/2, scp, sspm, dpm, mcupm, gz, ccu, vcp,
  gpueb, md1*, nvram, proinfo, lk1, bootloader2, para, otp, connsys...).
  الـ 22 سطر المتبقية هي `overlay` لمسارات product/system — لا يحتاجها
  الاسترجاع، والمنفذ المرجعي يحذفها أيضاً فتركتها خارجاً.
* **لا وحدات نواة في vendor_boot إطلاقاً** (0 ملف `.ko` في ramdisk الـ recovery،
  والـ 244 الموجودة في ramdisk الـ platform هي وحدات المنصة). وحدات اللمس
  الحقيقية تسكن في قسم `vendor_dlkm` المنطقي داخل `super.img`.

### ميزانية قسم vendor_boot

قبل التقليم (ما قِسته في البناء الفاشل 2026-10-08):

```
64.0 MiB  حجم القسم
-27.9 MiB ramdisk الـ platform (الستوك كما هو)
- 0.42 MiB الـ DTB (بحاويته)
- 0.001 MiB الجدول + vbmeta
= 35.6 MiB  أقصى حجم لـ ramdisk الاسترجاع المبني
```

والسطر الذي أفشل خطوة 16 بعد بناء ناجح 52 دقيقة:
`the recovery ramdisk is 41.0 MiB but only 35.6 MiB fit in vendor_boot`.

الميزانية المقيسة بعد التقليم (التشغيل 37855460306):

```
64.0 MiB  حجم القسم (67,108,864 بايت)
-21.0 MiB ramdisk الـ platform بعد التقليم (22,027,149 بايت)
- 0.42 MiB الـ DTB (444,841 + 64 حاوية)
- 0.07 MiB حصّة توقيع avbtool (69,632) + الجدول والمحاذاة (16 KiB)
= 42.5 MiB  أقصى حجم لـ ramdisk الاسترجاع المبني (44,550,794 بايت)
```

وقطعة الاسترجاع التي أنتجها البناء في ذلك التشغيل: **42,970,654 بايت (41.0 MiB)**
— أي أنها تدخل الآن بهامش 1.5 ميجا بدل أن تتجاوز السقف بـ 5.4 ميجا، ولهذا
يطبع السكربت تحذير "only 1.5 MiB of headroom left".

**التقليم هو الحل، وليس تصغير PBRP:** ramdisk الـ platform الستوك 72,030,720
بايت غير مضغوطة (749 مدخلاً) منها **13,639,266 بايت** مستخدمة الاسترجاع
الستوك المدمج — `system/bin/recovery` و`adbd` و`fastbootd` و
`update_engine_sideload` و`toybox` و`toolbox` و`sh` و`logd` و
`servicemanager` و`res/` و`librecovery_ui.so` — وهي كلها يُستبدل بها
ramdisk الاسترجاع الذي نبنيه. حذفها يوفّر ~5.5 ميجا في الصورة، فيصير السقف
**42.5 ميجا** بدلاً من 35.6 (المقيس أدناه)، والأصلي المسترجاع الستوك 13.5 ميجا فقط.

`make-vendor-boot.sh` بعد التقليم يتحقق قبل التغليف من:

* وجود كل ملف يحتاجه first-stage init (`system/bin/init` و`linker64`
  و`libc.so` و`libmtk_bsg.so` وخدمة BootControl و`first_stage_ramdisk/fstab.mt6899`
  و`lib/modules/modules.load`) — وإلا يفشل البناء بدلاً من الجهاز.
* بقاء 244 وحدة نواة كما هي.
* عدم بقاء أي قطعة VINTF `type="device"` تحت `/system`: القطعة هناك تُقرأ
  كـ framework fragment فيتوقف hwservicemanager عن تشغيل Keystore2 — وهذا
  سبب مستقل عن الحجم، ولذلك يُنقل بيان MediaTek BootControl إلى
  `vendor/etc/vintf/manifest/` ولا يُحذف.

ولذلك أيضاً يستخدم السكربت قطعة الاسترجاع التي بنىها البناء نفسه
(`obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4`)
حين تكون أصغر من إعادة تغليفنا.

### حصة avbtool من آخر القسم

الفشل الرابع في خطوة 16 (التشغيل 37855460306) لم يكن في الحجم: التقليم نجح
والصورة تُعبّأ في القسم. كان في التوقيع:

```
avbtool: Adding hash_footer failed: Image size of 67108864 exceeds maximum
image size of 67039232 in order to fit in a partition size of 67108864.
```

السبب: `make-vendor-boot.sh` كان يمرّر `--size 67108864` لأداة التعبئة،
فتكتب صورة بحجم القسم كاملاً، ثم يرفض avbtool إضافة توقيعه لأن التوقيع
(AVB hash footer) يسكن في آخر **69,632 بايت (0x11000)** من القسم ولا يجد
مكاناً في صورة ممتلئة. الحل: `--no-pad` — تُعبّأ الصورة إلى محاذاة الصفحة
فقط، ويكمل avbtool الحشو إلى 64 MiB مع التوقيع في النهاية. الصورة غير
الموقَّعة (‏`--no-avb`) تبقى محشوّة إلى حجم القسم لأنها هي التي تُفلَش.

ولذلك أيضاً صار السكربت يتحقق قبل التوقيع من أن محتوى الصورة لا يتجاوز
`67108864 - 69632`، بدل أن يكتشف ذلك avbtool بعد بناء كامل.

`tools/verify-tree.sh` يفحص قائمة التقليم مقابل الأرشيف الحقيقي (كل مسار
موجود، الأساسي ينجو، عدد الوحدات صحيح) لأن خطأً حرفياً في هذه القائمة لا
يظهر إلا على الجهاز.

### لماذا يُتحقَّق من الصورة في مجلد مستقل

خطوة 17 («Validate the image») فشلت في التشغيل 37890803758 **بعد** نجاح
البناء (خطوة 15) والتوقيع (خطوة 16):

```
sha256 digest of .../out/target/product/rodin/vendor_boot.img does not match digest in descriptor
.../avbtool: Error verifying descriptor.
vbmeta: Successfully verified footer and SHA256_RSA4096 vbmeta struct in .../vendor_boot-rodin.img
```

السبب ليس في الصورة: avbtool يقرأ وصف التوقيع (hash descriptor) للتحقق منه
من ملف باسم `اسم_القسم.img` **داخل مجلد الصورة نفسها**
(`AvbHashDescriptor.verify` في `avbtool.py`). وصورتنا تُجمَّع في
`out/target/product/rodin/` حيث يوجد أيضاً ناتج البناء الوسيط
`vendor_boot.img` — وهو ملف مختلف. فكان avbtool يقارن بصمة توقيعنا ببصمة
ذلك الملف الوسيط ويفشل، بينما التوقيع والفوتر سليمان.

الحل: تُنسخ الصورة إلى مجلد مؤقت باسم `vendor_boot.img` وحده، ويُتحقَّق منها
هناك. أُعيد إنتاج الفشل والنجاح محلياً بأداة AOSP `avbtool 1.3.0` قبل الدفع:
التحقق بجانب ملف `vendor_boot.img` آخر يعطي نفس الرسالة أعلاه مع خروج 1،
والتحقق من النسخة المعزولة يعطي `Successfully verified sha256 hash` مع خروج 0.
و`tools/verify-tree.sh` يفحص الآن أن الخطوة تُعزل النسخة بهذا الاسم، وأن
الاسم يطابق `--partition_name` في سكربت التوقيع.

## آلية التسليم

```
boot.img (GKI kernel) ──────────────┐
vendor_boot.img ─┬ platform ramdisk │→ البوت لودر يقلع recovery
                 ├ recovery ramdisk ┘  (جزئيتنا المبنية من المصدر)
                 ├ DTB (MTK wrapper)
                 └ vbmeta (يُعاد توقيعه)
```

الفلاش: `fastboot flash vendor_boot vendor_boot-rodin.img` ثم
`fastboot reboot recovery`.

## نقاط مفتوحة (تحتاج تأكيداً عند أول بناء)

| # | النقطة | كيف نتحقق |
|---|---|---|
| 1 | هل بنى الـ workflow جزئية recovery فعلاً داخل vendor_boot؟ | أمر `vendor_boot_tool.py info` يُطبعه في سجل البناء (يجب أن يظهر مدخلان: platform + recovery) |
| 2 | عمل اللمس: يحتاج ملفات `*.ko` الخاصة باللوح | فك ضغط `prebuilt/vendor_ramdisk00` بـ `lz4 -d` ثم انسخ `focaltech_touch_rodin.ko` / `goodix_core_rodin.ko` / `xiaomi_touch_rodin.ko` / `scp.ko` إلى `prebuilt/modules/` — تُضمَّن تلقائياً |
| 3 | نسخة Global تحتاج وحدات معدّلة (patched) حسب تقرير المنفذ المرجعي | إن كنت على Firmware Global ولم يعمل اللمس، هذه أول نقطة تحقيق |
| 4 | `PRODUCT_SHIPPING_API_LEVEL := 34` بينما الفلاشة Android 15/16 | ارفعه فقط إذا قبل الفرع ذلك؛ الرفع الخاطئ يكسر البناء |
| 5 | فرق في مقاس `super`: 9,125,756,928 (شجرة LineageOS) مقابل 11,811,160,064 (المنفذ المرجعي) | لا يؤثر على الاسترجاع إطلاقاً (لا نبني super.img)، لكن وثّقتُ الفرق |
| 6 | اختيار الفرع: `android-14.0` مقابل `android-12.1` | إذا فشل البناء على 14.0، أعد التشغيل على 12.1 (متوفّر كخيار في الـ workflow) |

## عند فشل الإقلاع

* شاشة سوداء مع رجوع للـ fastboot: غالباً الـ DTB أو الـ cmdline، أو أن الـ
  platform ramdisk المستخدم لا يطابق نسخة الفلاشة المثبتة على الجهاز. الحل
  الأسرع: أعد استخراج الـ prebuilts من نفس نسخة الفلاشة المثبّتة حالياً.
* رسائل `init: cannot find ...` في اللوغ: ملف من `device.mk` لم يُنسخ أو أن
  الـ blob ناقص.
* لا لمس: النقطة (2) أعلاه.
* لا فك تشفير: blobs الخاصة بـ KeyMint/Weaver/gatekeeper ناقصة
  (`proprietary/vendor/...`).
* `vendor_boot` لا يقبل الفلاش: تأكد أن الحجم 67,108,864 بالضبط
  (`stat -c %s`).

## الإقليم: ما قِسته فعلاً (2026-10-08) — تصحيح لما كُتب سابقاً

كنت أكتب أن الدامب «صيني». هذا **خطأ**، والقياس يقول غير ذلك:

| الدليل | القياس |
|---|---|
| `sha256(vendor_boot_stock.img)` | `f3e58747…e25177` = **مطابق بايت ببايت** لـ`HyperOS.4.0.3.0.Rodin.CN/images/vendor_boot.img` (الحزمة التي فُلّشت على الجهاز) |
| علامات الإقليم داخل `boot.img` | `WOJMIXM` (عالمي) |
| داخل `vendor_boot.img` | `WOJMIXM` ×3 و`missi/MISSI` ×25 |
| داخل `init_boot.img` | `WOJMIXM` ×2 |
| حجم ramdisk الـ platform عندنا | 29,231,353 — مقابل 29,235,080 (عند المنفذ المرجعي: عالمي) و29,188,968 (صيني) |
| وحدات اللمس عندنا (7 ملفات) | مطابقة **بالبايت** لمجلد `prebuilt/global/modules/` عند المنفذ — لا لجذر CN |
| الجهاز نفسه | `ro.boot.hwc=GL` · `vendor_dlkm`=`OS3.0.10.0.WOJMIXM` · `vendor`/`odm`=`WOJCNXM` · `system`=`WAACNXM` → مزيج: super صيني + سلسلة إقلاع عالمية |

الخلاصة العملية:

* على جهاز بإصدار الفلاشة نفسه: لا يتغيّر شيء سوى ramdisk الاسترجاع (النواة/DTB/ramdisk المنصة تبقى كما هي).
* على إصدار آخر (صيني أو عالمي مختلف): ramdisk المنصة مرتبط بالإصدار → أعد `extract-prebuilts.sh` من دامب ذلك الإصدار.
* **فك التشفير (FBE/MiTEE) لم يُثبَت**: المنفذ المرجعي يبني واجهة Weaver من المصدر (`init.recovery.keymint.rc` + `twrp.flags`)، ونحن نعتمد على blobs البائع فقط.
* المنفذ المرجعي يفصل بناء CN عن building global ويضيف: `tools/import-global-firmware-inputs.sh`، `tools/patch-recovery-touch-modules.sh`، `tools/build-system-compatible-vendor-boot.sh`، وتعديل `recovery.fstab`/`twrp.flags` — أي أن «صورة واحدة للجميع» ليست ادّعاءه هو أيضاً.

## الإسناد

بنية البناء لهذا اللوح (نمط ramdisk الـ platform + FBE + حزم اللمس) مبنية على
ما وثّقه المنفذ العام مفتوح المصدر:

* <https://github.com/woshimaniubi8/orangefox_twrp_device_xiaomi_rodin>
  (`BoardConfig.mk`, `device.mk`, `docs/*.md`, `fox_callback.sh`)

لم أنسخ ملفات شيفرة منه: أعدتُ كتابة الأدوات (بايثون/باش) من الصفر واختبرتها
على دامب جهازك، لكن قائمة مكوّنات الاسترجاع (blobs، وحدات اللمس، ترتيب
الأقسام) مستندة إلى عمله. أبقِ الإسناد إن نشرت الشجرة.

المصادر الأخرى: شجرة `LineageOS`/`xiaomi-mt6899-dev` لجهاز rodin (قيم
`BoardConfig` العامة)، ومستند `manifest_pb` الخاص بـ PBRP (بنية `pb_*.mk`).
