# PitchBlack Recovery لجهاز Poco X7 Pro / Redmi Turbo 4 (rodin)

شجرة جهاز (device tree) لبناء **PitchBlack Recovery Project (PBRP)** لجهاز rodin
بمشغّل MediaTek MT6899، مع بناء سحابي جاهز عبر GitHub Actions — لأن الهاتف نفسه
لا يستطيع بناء PBRP (الشجرة تحتاج ~83 جيجا مساحة و16 جيجا رام).

## الحالة بصراحة

| الجزء | الحالة |
|---|---|
| قيم العتاد (offsets, header v4, مقاسات الأقسام) | ✅ مأخوذة من **دامب فلاشتك الحقيقي** على الجهاز |
| استخراج الـ prebuilts (kernel / DTB / vendor ramdisk) | ✅ **مُجرَّب فعلياً** على دامبك وينتج نفس أحجام المرجع |
| أداة تجميع vendor_boot | ✅ **مُجرَّبة**: round-trip مطابق بايت ببايت للصورة الأصلية + اختبار تبديل ramdisk |
| فحوصات الـ fstab وملفات rc | ✅ مبنية على fstab الفلاشة الأصلية (mt6899) |
| ملفات blobs الخاصة (TEE/FBE/touch) | ⚠️ **ناقصة**: تحتاج جمعها من الفلاشة (سكربت جاهز) |
| بناء PBRP الفعلي | ⚠️ **لم يُبنَ بعد**: أول تشغيل للـ workflow قد يحتاج 1–3 محاولات |

لا أقدّم هذا كـ"رِكَفِري جاهز"، بل كـ**شجرة قابلة للبناء مع أدوات مُتحقَّق منها**؛
الخطوة الناقصة الوحيدة التي تحتاج جهازاً/بناءً هي تجربة الصورة على الهاتف.

## لماذا البناء على الهاتف مستحيل

المساحة المتاحة على جهازك الآن **1.6 جيجا** فقط، وبناء PBRP يكسر 80 جيجا.
لذلك المسار: ترفع هذا المجلد كمستودع GitHub → تشغّل الـ workflow → ينزل لك
`vendor_boot.img` جاهز للفلاش.

## كيف يعمل الاسترجاع على rodin (مهم)

rodin ليس جهاز recovery تقليدي:

* الكيرنل في `boot.img` (GKI، header v4)، والاسترجاع **لا يحمل كيرنل خاص به**.
* صور `vendor_boot.img` الأصلية تحتوي **ramdisk نوع platform** (تعريفات
  التخزين/الشاشة من MediaTek) + **ramdisk نوع recovery**.
* الـ DTB داخل vendor_boot **مغلّف بحاوية MTK من 64 بايت** (وثّقنا ذلك بالقياس).
* لذلك لا يكفي `mka vendorbootimage` وحده: البناء يعيد صنع ramdisk الـ platform
  من المصدر، وهو **ليس** مكافئاً للأصلي. الحل عندنا: إعادة تجميع vendor_boot
  مع الاحتفاظ بـ ramdisk الأصلي واستبدال جزئية الـ recovery فقط.

النتيجة: **`vendor_boot.img` بحجم 67,108,864 بايت بالضبط** تُفلَش على قسم
`vendor_boot`، ثم تقلع إلى الاسترجاع.

### ميزانية الحجم (قيد حقيقي)

قسم `vendor_boot` عندك 64 ميجا، ومنها 27.9 ميجا لـ ramdisk الـ platform +
0.42 ميجا للـ DTB + ~1 كيلو للجدول وvbmeta. أي أن **الاسترجاع المبني يجب أن
يبقى تحت 35.7 ميجا** (الأصلي كان 13.5 ميجا فقط!). `make-vendor-boot.sh` يقيس
هذا ويفشل برسالة واضحة مع حلول قبل أن يرفض المجمّع الصورة. لهذا السبب لا ننسخ
وحدات النواة كلها (244 وحدة = 30 ميجا).

## المحتويات

```
device/xiaomi/rodin/
├── BoardConfig.mk              إعدادات اللوح (قيم من دامبك)
├── device.mk / pb_rodin.mk      تعريف منتج PBRP ومحتوى الـ ramdisk
├── AndroidProducts.mk          أهداف lunch (pb_rodin-eng)
├── vendorsetup.sh
├── recovery/root/              fstab + twrp.flags + init rc + first_stage
├── prebuilt/                   مخرجات الاستخراج (kernel, dtb, vendor_ramdisk00, stock vendor_boot)
├── proprietary/                تُملأ بالـ blobs (vendor-blobs.mk + README)
└── tools/
    ├── extract-prebuilts.sh    يستخرج الـ prebuilts من دامب الفلاشة (مُجرَّب)
    ├── vendor_boot_tool.py     parse/rebuild/استخراج ramdisks (مُجرَّب round-trip)
    ├── vendor_ramdisk.py       فكّ lz4 + قراءة cpio ببايثون خالص (بدون tools)
    ├── collect-blobs.sh        جمع الـ blobs + الوحدات (+ --check)
    └── make-vendor-boot.sh     تجميع + توقيع + حماية الحجم
.github/workflows/pbrp-build.yml  البناء السحابي
tools/setup-swap.sh               swap للـ CI
docs/                             ملاحظات rodin + البناء والفلاش
```

## الخطوات العملية

### 1) املأ الـ prebuilts (على الهاتف ممكن)

```bash
cd device/xiaomi/rodin
tools/extract-prebuilts.sh /storage/emulated/0/HyperOS.4.0.3.0.Rodin.CN/images
```

تنتج: `prebuilt/kernel` و`prebuilt/vendor_ramdisk00` و
`prebuilt/dtb/mt6899-rodin.dtb` و`prebuilt/vendor_boot_stock.img`.

### 2) اجمع الـ blobs (تحتاج PC أو استخراج من الفلاشة)

هذه الملفات مسؤولة عن **فتح تشفير /data** (KeyMint/Weaver عبر MiTEE) وعن
**عمل اللمس** داخل الاسترجاع. راجع `device/xiaomi/rodin/proprietary/README.md`.
بدونها: البناء ينجح لكن الاسترجاع أنقص (لا فك تشفير ولا لمس).

### 3) ارفع المستودع وشغّل البناء

```bash
git init && git add -A && git commit -m "PBRP device tree for rodin"
git remote add origin git@github.com:<user>/<repo>.git
git push -u origin main
```

ثم من تبويب Actions: `Build PBRP for rodin` → Run workflow
(الفرع الافتراضي `android-14.0`). بعد ~1–3 ساعات ينزل
`vendor_boot-rodin.img` في الـ artifacts.

### 4) الفلاش

```bash
fastboot flash vendor_boot vendor_boot-rodin.img
fastboot reboot recovery
```

للرجوع للوضع الأصلي:

```bash
fastboot flash vendor_boot device/xiaomi/rodin/prebuilt/vendor_boot_stock.img
```

## تحذيرات

* **البوت لودر يجب أن يكون مفتوحاً** (جهازك يبدو كذلك لأنه يحمل Magisk/KSU).
* احتفظ دائماً بـ `prebuilt/vendor_boot_stock.img` — هذه شبكة الأمان الوحيدة.
* لا تفلش `recovery.img` على هذا الجهاز؛ الاسترجاع يعمل من `vendor_boot`.
* إن لم يقلع الاسترجاع: التقط `recovery.log` من `/tmp` داخل الاسترجاع أو استخدم
  `adb logcat` من وضع fastbootd، وراجع `docs/RODIN-NOTES.md`.
* توقيع AVB يبقى بمفتاح AOSP التجريبي: هذا يعني أن الصورة **غير موقَّعة رسمياً**،
  وهو المتوقع لأي recovery غير رسمي.

## الإسناد (مهم قانونياً وأخلاقياً)

قيم العتاد وبنية images مؤكَّدة من دامب الجهاز نفسه. البنية العامة لبناء
الاسترجاع على هذا اللوح استَفدتُ فيها من المنفذ العام (مفتوح المصدر) لـ rodin:

* <https://github.com/woshimaniubi8/orangefox_twrp_device_xiaomi_rodin>

لم أنسخ شيفرته كما هي، لكن qائمة الـ blobs المطلوبة وتقنيات العمل (ramdisk
الأصلي + FBE + اللمس) مبنية على ما وثّقه صاحب ذلك المنفذ. احتفظ بالإسناد إن
نشرت شجرتك. PBRP نفسه Apache-2.0، وTWRP الذي يبني عليه GPL.
