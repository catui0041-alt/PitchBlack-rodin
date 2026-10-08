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
