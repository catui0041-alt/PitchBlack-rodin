# ملاحظات rodin التقنية

كل رقم في هذا الملف **مقيس من دامب الفلاشة الموجود على جهازك**، لا منقول من
مصدر عام، ما لم يُذكر خلاف ذلك.

## قياسات الصور الأصلية

| الصورة | النوع | القياس المؤكد |
|---|---|---|
| `boot.img` | ANDROID! header v4 | page=4096، kernel=17,184,688 بايت، ramdisk=0 |
| `init_boot.img` | ANDROID! header v4 | kernel=0، ramdisk=2,479,854 بايت |
| `vendor_boot.img` | VNDRBOOT header v4 | ramdisk section=43,386,290 / dtb=444,841 / table=216 / vbmeta=704 |
| `recovery.img` (stock) | ANDROID! header v4 | kernel=**0**، ramdisk=24,558,346 |

تفصيل vendor_boot:

```
0x000     header v4 (2128 بايت) — cmdline: bootopt=64S3,32N2,64N2
0x1000    [0] platform ramdisk  29,241,054 بايت  lz4 legacy (02 21 4c 18)
0x1BE3EDE [1] recovery ramdisk  14,145,236 بايت  lz4 legacy
0x2962000 DTB region: 64 بايت حاوية MTK
0x2962040 FDT الحقيقي: 444,841 بايت (d0 0d fe ed) — نفس بايتات كل النسخ المقيسة
0x29CF000 جدول ramdisks: 2 مدخلات × 108 بايت
0x29D0000 كتلة vbmeta مدمجة: "AVB0" — النمط `algorithm NONE` (بلا توقيع RSA)
...       AVB footer في آخر القسم ("AVBf") عند 0x3FFFFC0
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
| 7 | لم يُطبَّق بعد: المرجع يحذف `mediatek,usb-offload` من `/soc/usb0@11201000/xhci0@11200000` في الـ DTB ليعمل USB/ADB داخل الاسترجاع | إن أقلع الاسترجاع بلا adb، هذا أول تعديل: أضف خطوة DTB مثل `tools/make-recovery-host-dtb.py` في المرجع (تحتاج `dtc`/`fdtget`/`fdtput`، وهي مثبّتة في الـ workflow) |

## عند فشل الإقلاع

* **العلق عند لوجو POCO بلا إعادة تشغيل**: أول ما يُتفحّص هل قطعة الاسترجاع
  تحجب ملفاً من قطعة الـplatform — خصوصاً `first_stage_ramdisk/fstab.mt6899`.
  الأجزاء تُفكّ بالترتيب، فملف الاسترجاع يلغي جدول الفيرموير (mi_ext والـoverlays
  و`avb_keys`) ويتوقف first-stage قبل الواجهة. الحارس في
  `make-vendor-boot.sh` يمنع ذلك، و`tools/verify-tree.sh` يفحصه.
* **لوجو يظهر ثم يختفي ويعيد الجهاز التشغيل (بلا أي رسالة)**: أول ما يُتفحّص
  `vermagic` لوحدات ramdisk المنصة مقابل نواة الجهاز المثبّتة. هذا هو العرض
  المميّز للفلاشة المبنية على إصدار آخر (انظر قسم الحادثة أدناه).
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
| `sha256(vendor_boot_stock.img)` | `d6921924…9aa85f60` = الصورة التي يعمل بها الجهاز فعلاً (بصمة `OS3.0.302.0.WOJMIXM`، بناء 2026-08-26) — هذه هي خط الأساس الحالي |
| علامات الإقليم داخل الصورة | `WOJMIXM` فقط؛ لا وجود لأي `WOJCNXM` |
| حجم ramdisk الـ platform عندنا | 29,241,054 (749 مدخلاً، 244 وحدة) مقابل 29,231,353 في خط الأساس السابق `OS3.0.8.0.WOJMIXM` |
| `vermagic` لوحدات المنصة | **`6.6.118-android15-8-g461cf67b3067`** مقابل **`6.6.89-android15-8-g03fb7c87b0b5`** في النسخة السابقة — فرق نواة كامل، لا اختلاف تجميلي |
| DTB | `sha256 = 80fccd02…` **مطابق** بين الإصدارين ⇒ لا يتغيّر بتغيّر الفلاشة |
| وحدات اللمس عندنا (7 ملفات) | `vermagic = 6.6.89…` ⇒ **لا تُحمَّل على نواة 6.6.118**: يجب إعادة سحبها من `vendor_dlkm` في `super.img` للفلاشة المثبّتة |
| الجهاز نفسه | `ro.boot.hwc=GL` · `vendor_dlkm`=`OS3.0.10.0.WOJMIXM` · `vendor`/`odm`=`WOJCNXM` · `system`=`WAACNXM` → مزيج: super صيني + سلسلة إقلاع عالمية |

الخلاصة العملية:

* على جهاز بإصدار الفلاشة نفسه: لا يتغيّر شيء سوى ramdisk الاسترجاع (النواة/DTB/ramdisk المنصة تبقى كما هي).
* على إصدار آخر (صيني أو عالمي مختلف): ramdisk المنصة مرتبط بالإصدار → أعد `extract-prebuilts.sh` من دامب ذلك الإصدار. **لا تُخلط أبداً**: جزء `type-1 platform` من إصدار مع نواة إصدار آخر.
* ما سبق ليس تنظيراً: هو ما أسقط أول فلاش حقيقي (انظر قسم الحادثة أدناه).
* **فك التشفير (FBE/MiTEE) لم يُثبَت**: المنفذ المرجعي يبني واجهة Weaver من المصدر (`init.recovery.keymint.rc` + `twrp.flags`)، ونحن نعتمد على blobs البائع فقط.
* المنفذ المرجعي يفصل بناء CN عن building global ويضيف: `tools/import-global-firmware-inputs.sh`، `tools/patch-recovery-touch-modules.sh`، `tools/build-system-compatible-vendor-boot.sh`، وتعديل `recovery.fstab`/`twrp.flags` — أي أن «صورة واحدة للجميع» ليست ادّعاءه هو أيضاً.

## حادثة البوتلوب (2026-10-09) — السبب الجذري والإصلاح

أول فلاش حقيقي على جهاز المختبر (Global): لوجو POCO يظهر لحظة ثم تختفي
الشاشة ويعيد الجهاز التشغيل بلا أي رسالة. القياسات:

| ما قِسناه | القيمة |
|---|---|
| بناء #16 المُفلَّش | 67,108,864 بايت، AVB سليم، رِمدِسكان اثنان (platform + recovery) |
| الفلاشة المثبّتة على الجهاز | `OS3.0.302.0.WOJMIXM` — نواة **6.6.118**-android15-8-g461cf67b3067 |
| خط أساس البناء حينها | `OS3.0.8.0.WOJMIXM` — نواة **6.6.89**-android15-8-g03fb7c87b0b5 |
| ملفات ramdisk المنصة المتغيّرة | **248 من 749** (معظمها `lib/modules/*.ko`)، و13 يختلف حجمها |

الأثر: النواة ترفض كل وحدة بـ`vermagic` مختلف (`invalid module format`)، فيفشل
first-stage init في تحميل وحدات التخزين/العرض ⇒ panic ⇒ إعادة تشغيل متكررة
بعد اللوجو. الأمر **لا علاقة له بـ**حجم الصورة، ولا بتوقيع AVB، ولا بالـ DTB،
ولا بالجزء المبني من المصدر (لم يظهر أي سطر `init:` في اللوغ لأن الإقلاع لم
يصل إليه).

الإصلاح المطبّق:

* `prebuilt/vendor_boot_stock.img` ← الفلاشة المثبّتة نفسها (`d6921924…9aa85f60`).
* `prebuilt/vendor_ramdisk00` ← جزء `type-1 platform` من الصورة نفسها
  (`513261fb…83de87`، 29,241,054 بايت، 749 مدخلاً، 244 وحدة بنواة 6.6.118).
* الـ DTB بلا تغيير: بايتاته مطابقة بين الإصدارين (`80fccd02…`).
* `tools/verify-tree.sh` يحذّر الآن عند اختلاف `vermagic` بين وحدات
  `prebuilt/modules/` ووحدات ramdisk المنصة — أي أنه كان سيكشف هذا قبل الفلاش.

المتبقّي بعد هذا الإصلاح:

1. وحدات اللمس السبعة ما زالت بنواة 6.6.89 ⇒ لا لمس في الاسترجاع حتى تُسحب
   من `vendor_dlkm` داخل `super.img` للفلاشة المثبّتة.
2. نمط توقيع AVB: المخزون في الإصدارين `algorithm NONE`، وبناؤنا
   `SHA256_RSA4096` بمفتاح اختبار. لم يُثبَت قبول البوت لودر له، وهو المُتغيّر
   الثاني إن تكرّر البوتلوب بعد إصلاح الإصدار.

## حادثة البوتلوب الثانية (2026-10-17) — السبب الحقيقي: حجم الـ ramdisk المشترك

بعد إصلاح الإصدار (خط أساس `OS3.0.302.0`) بقي البوتلوب كما هو، وكذلك على خط
الأساس `OS3.0.8.0` — أي أن الإصدار لم يكن السبب الوحيد. القياس الحاسم:

| ما قِسناه | القيمة |
|---|---|
| الصورة الأصلية (تعمل) | platform 29,231,353 + recovery 14,145,147 = **43,376,500** بايت |
| بناؤنا #16 و#17 (بوتلوب) | platform ~22,0xx,xxx + recovery 42,970,640 = **65,004,438** بايت |
| المرجع OrangeFox (يقلع فعلاً) | platform 17.3 ميجا (zstd) + recovery ~37.4 ميجا = **~54.8 ميجا** |
| حدّ العمل المعتمد لهذا اللوح | **< 62,000,000 بايت** للـ ramdisk المشترك |

النواة تضع الـ initramfs عند `ramdisk_addr = 0x66f00000`؛ ما يتجاوز الحدّ
يدخل في الحجز التالي ويُكتب فوق نفسه أثناء الفكّ، فيموت first-stage init قبل أن
يطبع أي سطر — وهذا هو بالضبط «لوجو يظهر ثم يختفي ويعيد التشغيل بلا رسالة».

الإصلاح المطبَّق في `make-vendor-boot.sh`:

* **تقليم قطعة الاسترجاع** (0.5+ ميجا مضغوطة): خطوط اللغات غير الإنجليزية،
  خطوط CJK (`DroidSansFallback`، `NotoSansCJKjp`، `RoboNoto-Medium`) مع حذف
  تعريفاتها من `twres/ui.xml`، `magiskboot`، `bash`، `nano`،
  `libprotobuf-cpp-lite`، `libclang_rt.ubsan`، وملفّا `ramdisk-files.*`.
  البقاء المفروض: `init`، `system/bin/init`، `recovery`، `adbd`، `minadbd`،
  `fastbootd`، `keystore2`، `libandroidicu`، مكتبات اللمس، `recovery.fstab`.
  (القياسات في هذا القسم تخصّ الجيل السابق، حيث كان الحجم يُعالَج بالتقليم
  وحده؛ انظر «حادثة البوتلوب الثالثة» لسبب تغيير المقاربة.)
* **حراسة صريحة**: `COMBINED_RAMDISK_LIMIT=62000000` يفشل البناء بدل أن يقلع.
* **التوقيع بنمط المخزون**: `avbtool add_hash_footer` بلا `--key` وبلا
  `--algorithm` ⇒ `algorithm NONE` وvbmeta بحجم 704 بايت مثل الصورة الأصلية،
  لا `SHA256_RSA4096` بمفتاح اختبار (2112 بايت) بمفتاح لا يعرفه البوت لودر.

## حادثة البوتلوب الثالثة (2026-11-01) — الجذر: قطعة الاسترجاع تحجب جدول الفيرموير

العلق عند لوجو POCO مع `vendor_boot-rodin-HOS-AVB-ENABLED-6.6.118.img` لم يكن
حجماً ولا توقيعاً. السبب:

* الصورة الأصلية تحمل في **قطعة الـplatform** جدول first-stage الحقيقي:
  `first_stage_ramdisk/fstab.mt6899` بـ175 سطراً، فيه `mi_ext` و25 نقطة تركيب
  overlay لـ`product`/`system` وقائمة `avb_keys`.
* شجرة الجهاز كانت تُثبّت نسخة مقلَّمة منه (23 سطراً) باسم
  `first_stage_ramdisk/fstab.mt6899` **داخل قطعة الاسترجاع**.
* الأجزاء في ramdisk الخاص بـ`vendor_boot` تُفكّ فوق بعضها بالترتيب، فملف
  الاسترجاع يحلّ محل ملف الـplatform — فيفقد first-stage كل نقاط mi_ext/overlay
  ويتوقف قبل أن يصل إلى واجهة الاسترجاع.

الإصلاح:

* `device.mk` يثبّت جدول الشجرة باسم `first_stage_ramdisk/fstab.emmc` فقط —
  تماماً كما يفعل المخزون (نسخته الوحيدة هناك هي `fstab.emmc`). وأُعيدت تسمية
  الملف نفسه في الشجرة أيضاً: بناء PBRP ينسخ مجلد `recovery/root` بأكمله إلى
  القطعة، فقاعدة `PRODUCT_COPY_FILES` وحدها لا تمنع وصول الاسم القديم
  `fstab.mt6899` (وهذا بالضبط ما أوقف البناء الأول: الحارس رآه في
  `recovery/root` المبنية).
* `make-vendor-boot.sh` يرفض البناء إذا وجد في قطعة الاسترجاع أي مسار يملكه
  الـplatform (`FORBIDDEN_RECOVERY_PATHS`)، فلا يمكن إعادة الخطأ بصمت.
* `tools/verify-tree.sh` يفحص ثلاثة أشياء: أن `device.mk` لا يثبّت
  `fstab.mt6899`، وأن الحارس موجود، وأن `prebuilt/vendor_ramdisk00` نفسه يحمل
  `mi_ext` و`lowerdir=/mnt/vendor/mi_ext`.

وبنفس الحادثة تُرك تقليم الـplatform نهائياً:

* قطعة الـplatform تُنقل **كما هي بايتاً ببايت** (نفس محتوى الفيرموير: init
  والمكتبات وVINTF و244 وحدة نواة وجدول fstab الكامل)، ويُعاد ضغطها من LZ4 إلى
  `zstd -19` فقط: 72,030,720 بايت ⇒ ~17.35 ميجا بلا تغيير في المحتوى.
  هذا ما يفتح المكان لقطعة استرجاع بحجم PBRP.
* قطعة الاسترجاع تبقى LZ4 كما في المخزون.
* نواة 6.6.118 المثبّتة على الجهاز تفكّ initramfs المضغوط بـzstd (مُتحقَّق من
  `boot.img` نفسه)، ولذلك عاد zstd مسموحاً بعد أن كان ممنوعاً في الجيل السابق.

## أربع نسخ إصدار (2026-11-01)

`make-vendor-boot.sh` ينشر أربع صور، والمحاذاة كما يلي:

| الملف | PLATFORM | AVB |
|---|---|---|
| `vendor_boot-rodin-HOS-AVB-ENABLED.img` | `prebuilt/vendor_ramdisk00` كما هو، مضغوط `zstd -19` | hash footer غير موقَّع مثل المخزون |
| `vendor_boot-rodin-HOS-AVB-DISABLED.img` | نفسه، مع تجريد `avb`/`avb_keys` من fstab الـplatform | hash footer، بلا bootconfig |
| `vendor_boot-rodin-AOSP-AVB-ENABLED.img` | `prebuilt/aosp/vendor_ramdisk00` كما استُورد (LZ4) | مثل المخزون + bootconfig الروم |
| `vendor_boot-rodin-AOSP-AVB-DISABLED.img` | نفسه بعد تجريد `avb` وإعادة ضغط LZ4 | مثل المخزون + bootconfig الروم |

نسخ AVB-DISABLED لا تكتب أي تجاوز لحالة الإقلاع في bootconfig؛ التغيير الوحيد
هو حذف `avb`/`avb_keys` من `first_stage_ramdisk/**/fstab.*` في الجزئين. هذا هو
نفس ما يفعله المرجع المُتحقَّق منه على هذا اللوح.

نسخ AOSP تحتاج مدخلاتها الخاصة (`prebuilt/aosp/vendor_ramdisk00` و`bootconfig`)
تُستورد من `vendor_boot.img` الخاص بالروم عبر
`tools/import-aosp-vendor-boot.sh`؛ لا تُبنى من جزء هايبر أبداً. إن غابت المدخلات
يُبنى زوج HOS وحده ويُطبع سبب التخطي.

## حادثة التعليق الرابعة (2026-11-01) — قطعة الاسترجاع نفسها وبصمة AVB

بعد إصلاح جدول first-stage بقي الجهاز يعلق عند اللوجو، وإرجاع `vendor_boot`
الأصلي يعيده. قِيست صورتان: صورتنا المبنية (`3285f4ec…`) والمخزون، وظهر
فرقان ملموسان:

1. **الملفات المشتركة بين القطعتين.** قطعتا vendor_boot تُفكّان كأرشيف واحد
   متسلسل، فكل مسار في قطعة الاسترجاع يحلّ محلّ نظيره في قطعة الـplatform.
   المخزون مبني بحيث لا يغيّر شيئاً: قطعة استرجاعه **لا تحمل
   `system/bin/init` إطلاقاً**، و`sepolicy` و`plat_file_contexts` فيها
   **مطابقة بايتاً ببايت** لما في الـplatform. قطعة PBRP، بالمقابل، تحمل
   `system/bin/init` و`sepolicy` و`plat_*_contexts` و`prop.default` من
   Android 14 فوق platform من Android 15. إن كان `lk` يمرّر القطعتين معاً في
   الإقلاع العادي (وهو ما يفسّر لماذا لا تصلح صورة "استرجاع فقط" على هذا
   اللوح)، فهذه الملفات تكفي وحدها لتعليق الإقلاع عند اللوجو.
2. **بصمة AVB في الذيل.** المخزون يحمل
   `com.android.build.vendor_boot.fingerprint` بقيمة
   `alps/hal_mgvi_…:15/…/OS3.0.302.0.WOJMIXM` (Global)، بينما `pb_rodin.mk`
   كان يبني ببصمة `Redmi/rodin/rodin:…/OS3.0.303.0.WOJCNXM` (صينية)، وقد
   نُسخت إلى ذيل صورتنا. هذا خلط أقاليم صريح، وقد يقارنه البوت لودر ببصمة
   `vbmeta` فيرفض الصورة.

الإصلاحات:

* `pb_rodin.mk` صار يبني ببصمة نسخة الجهاز نفسها
  (`POCO/rodin_global/rodin:15/AP3A.240905.015.A2/OS3.0.302.0.WOJMIXM`).
* `make-vendor-boot.sh` لم يعد يكتب بصمة البناء في الذيل، بل **يقرأ بصمة
  المخزون من ذيله** عبر
  `vendor_boot_tool.py avb-prop <image> com.android.build.vendor_boot.fingerprint`
  وينسخها كما هي — فتطابق الصورةُ الفيرمويرَ الذي أُخذت منه، لأي إقليم.
* `tools/verify-tree.sh` يتحقق من الأمرين: أن البصمة تُقرأ من المخزون، وأن
  `pb_rodin.mk` لا يذكر إقليماً آخر.
* أُضيفت أداة `strip_platform_owned` إلى الحزمة: تحذف من قطعة الاسترجاع كل
  مسار يملكه الـplatform، فتصبح النتيجة في الملفات المشتركة مماثلة للمخزون
  تماماً. استثناء واحد مهم: قطعة الـplatform نفسها تحمل استرجاع المخزون
  (`system/bin/recovery` و`fastbootd` و`adbd` و`toybox` و`system/etc/recovery.fstab`
  و`res/`)، فالقاعدة العمياء "الـplatform يفوز" كانت ستستبدل PBRP باسترجاع
  المخزون. لذلك تُستثنى حمولة الاسترجاع نفسها (`RECOVERY_OWNED_PATHS`)، وهي
  ملفات لا يقرأها init في الإقلاع العادي إطلاقاً. لم تُطبَّق على الإصدار بعد؛
  هي صورة تشخيص أولاً.

### سلّم التشخيص (خمس صور، `diagnostics=true`)

تُفلش بالترتيب، وتُسجَّل النتيجة قبل الانتقال للتالية، ودائماً على الفتحة
التي يذكرها `fastboot getvar current-slot`:

| # | الصورة | ما تعزله |
|---|---|---|
| 1 | `DIAG-CONTROL-stock` | المخزون حرفياً — إن علق فالفلاش/الفتحة/اسم القسم هي الخطأ |
| 2 | `DIAG-ZSTD-STOCKRECOVERY` | platform مضغوط zstd + قطعة استرجاع المخزون — يختبر الضغط والذيل |
| 3 | `DIAG-STOCKPLATFORM-PBRP` | platform المخزون كما هو + قطعة PBRP — يختبر قطعة PBRP نفسها |
| 4 | `DIAG-STOCKPLATFORM-PBRP-CLEAN` | مثل 3 بعد حذف كل ما يملكه الـplatform — يختبر الحجب |
| 5 | `DIAG-ZSTD-PBRP-CLEAN` | شكل الإصدار المقترح: zstd + قطعة منظّفة |

القراءة: 2 يقلع و3 يعلق ⇒ المشكلة حجب الملفات، و4/5 هما الإصلاح. 2 يعلق ⇒
المشكلة في إعادة ضغط الـplatform أو الذيل، لا في PBRP. 3 يقلع ⇒ قطعة PBRP
بريئة والاحتمال الأقوى البصمة/الذيل.

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

مرجع تصميم (تحليل فقط، بلا نسخ):

* <https://github.com/NEESCHAL-3/OrangeFox-rodin-source> — منه أخذنا **الفكرة**
  فقط: إبقاء قطعة الـplatform حرفياً وإعادة ضغطها `zstd -19`، حدّ 62,000,000
  بايت، تجريد `avb`/`avb_keys` لنسخة AVB-DISABLED بلا تجاوز bootconfig، وموضع
  جدول first-stage. لم يُنسخ منه أي ملف؛ أدوات هذه الشجرة مكتوبة من الصفر
  ومُتحقَّق منها بـ`tools/verify-tree.sh`.
