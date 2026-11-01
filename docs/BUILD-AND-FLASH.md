# البناء والفلاش

## 1) تجهيز الـ prebuilts

من مجلد `device/xiaomi/rodin`:

```bash
bash tools/extract-prebuilts.sh <مجلد يحتوي boot.img و vendor_boot.img>
```

إن لم تمرّر مساراً، يُجرّب تلقائياً:
`/storage/emulated/0/HyperOS.4.0.3.0.Rodin.CN/images`.

المخرجات المتوقعة (من دامب الفلاشة المثبّتة — حاليًا عالمي `OS3.0.302.0.WOJMIXM`):

```
prebuilt/kernel                    17,184,688 بايت  (lz4 legacy — من الإصدار السابق، لا يُضمَّن في البناء)
prebuilt/vendor_ramdisk00          29,241,054 بايت  (lz4 legacy، 244 وحدة بنواة 6.6.118)
prebuilt/dtb/mt6899-rodin.dtb        444,841 بايت  (FDT)
prebuilt/dtb/mt6899-rodin.dtb.mtk-wrapped  نسخة بالحاوية الأصلية للمقارنة
prebuilt/vendor_boot_stock.img      67,108,864 بايت (شبكة الأمان للرجوع)
```

## 2) بناء سحابي (المسار الموصى به)

1. ارفع المستودع إلى GitHub.
2. Actions → **Build PBRP for rodin** → Run workflow.
   * `pbrp_branch`: `android-14.0` افتراضياً، و`android-12.1` بديل.
   * `build_jobs`: 4 مناسب لرَنر 16 جيجا. قلّله إذا رأيت swap كثيف.
   * `sign_image`: ينصح بإبقائه `true`.
3. عند النجاح حمّل الـ artifact: `vendor_boot-rodin.img` + `.sha256` + `build-info.md`.

الـ workflow يتحقق قبل الفلاش من:
* وجود الـ prebuilts وبحجم `vendor_boot_stock.img` الصحيح.
* مساحة قرص ≥ 98 جيجا وذاكرة ≥ 14 جيجا (وإلا يفشل برسالة واضحة بدل السقوط في منتصف البناء).
* أن الصورة النهائية = 67,108,864 بايت، وأن `sha256sum --check` يمر، وأن
  `avbtool verify_image` ينجح، وأن أداة التجميع تعيد قراءة الصورة بنجاح.

### إضافة الـ blobs إلى البناء

الـ blobs تُنسخ إلى `recovery/root/...` عبر `proprietary/vendor-blobs.mk`. أي
ملف غير موجود يُتجاهل بصمت، فتحقق من سجل البناء والأخطاء داخل الاسترجاع:

```bash
# داخل الاسترجاع
adb shell "logcat -d | grep -Ei 'keymint|weaver|gatekeeper|touch'"
```

## 3) بناء محلي (على PC)

```bash
repo init --depth=1 -u https://github.com/PitchBlackRecoveryProject/manifest_pb -b android-14.0
repo sync -c -j8 --no-clone-bundle --no-tags
cp -a <هذا المستودع>/device/xiaomi /path/to/PBRP/device/  # أو rsync
cd /path/to/PBRP

export ALLOW_MISSING_DEPENDENCIES=true
export GOMEMLIMIT=6GiB GOGC=20 _JAVA_OPTIONS=-Xmx3g
. build/envsetup.sh
lunch pb_rodin-eng
mka vendorbootimage

# ثم التجميع النهائي (يستبدل ramdisk الـ recovery ويوقّع الصورة)
bash device/xiaomi/rodin/tools/make-vendor-boot.sh
```

المتطلبات: ~100 جيجا مساحة، 16 جيجا رام على الأقل + swap (استخدم
`bash tools/setup-swap.sh`)، وlz4 وpython3.

> استدعِ كل سكربت عبر `bash` دائماً (كما يفعل الـ CI). الشجرة تُحرَّر من
> الهاتف، و`/sdcard` لا يحمل بت تنفيذ أصلاً، فلا يمكن تثبيته في git من هناك؛
> والاستدعاء المباشر (`tools/x.sh`) يفشل بـ `Permission denied` وexit 126
> بعد نجاح البناء كاملاً. السكربتات التنفيذية محفوظة بـ mode 100755 في
> الفهرسه (`bash tools/verify-tree.sh` يفحص ذلك).

## 3.5) النسخ الأربع

`make-vendor-boot.sh` ينتج الآن أربع صور في `out/target/product/rodin/`:

| الصورة | متى تُستعمل |
|---|---|
| `vendor_boot-rodin-HOS-AVB-ENABLED.img` | روم هايبر/ستوك بتوقيع AVB الطبيعي |
| `vendor_boot-rodin-HOS-AVB-DISABLED.img` | روم يتطلب تعطيل AVB في المرحلة الأولى |
| `vendor_boot-rodin-AOSP-AVB-ENABLED.img` | روم AOSP — يحتاج `prebuilt/aosp/` |
| `vendor_boot-rodin-AOSP-AVB-DISABLED.img` | روم AOSP مع AVB معطّل |

نسخ `AVB-DISABLED` لا تكتب أي شيء في bootconfig؛ الفرق الوحيد أنها مُجرَّدة من
`avb`/`avb_keys` في `first_stage_ramdisk/**/fstab.*` داخل كلا الجزئين (الـplatform
والاسترجاع)، ثم يُعاد ضغط الـplatform كما هو. هذا يطابق ما يفعله المرجع المُتحقَّق
منه على نفس اللوح.

> **تحذير الجدول الأول**: لا تجعل أي ملف داخل قطعة الاسترجاع يحمل نفس مسار ملف
> في قطعة الـplatform (خصوصاً `first_stage_ramdisk/fstab.mt6899`)؛ فالأجزاء تُفكّ
> بالترتيب وملف الاسترجاع يحجب ملف الفيرموير — وهو سبب التوقف عند لوجو POCO.

لزوج AOSP، استورد مدخلاته من `vendor_boot.img` الخاص بالروم أولاً (لا يُخلط
أبداً مع جزء هايبر):

```bash
bash device/xiaomi/rodin/tools/import-aosp-vendor-boot.sh /path/to/rom/vendor_boot.img
# ثم نفس الأمر أعلاه؛ يبني الأربع
```

خيارات: `--profile hos|aosp|all` (افتراضياً all)، `--out-dir`، `--no-avb` (بلا
أي AVB footer).

## 4) الفلاش

```bash
# احتياط إلزامي أولاً
adb reboot bootloader
fastboot getvar current-slot
fastboot getvar partition-size:vendor_boot     # يجب أن يطبع 0x4000000 (64 MiB)
fastboot flash vendor_boot_a vendor_boot-rodin-HOS-AVB-ENABLED.img
fastboot reboot recovery
```

اسم القسم المطلوب: `vendor_boot_a` أو `vendor_boot_b` (الفتحة النشطة من
`current-slot`). لا تستعمل `vendor_boot_ab`.

إن رفض البوت لودر الاسم المجرّد (رسالة "partition not found") فهذا **خطأ بلا كتابة**،
واستعمل اسم الفتحة النشطة من `current-slot` (عادة `_a`):

```bash
fastboot flash vendor_boot_a vendor_boot-rodin.img
```

وتقبل بعض بوت لودرات MTK الصيغة `_ab` كما تفعل حزمة الفلاش الخاصة بالجهاز. كل هذه
الأسماء تكتب **القسم نفسه**؛ لا تفلّش أي اسم آخر في هذه الجلسة، وبالخصوص
`preloader`/`lk`/`bootloader` — فهنا فقط يوجد الهاردبريك الحقيقي.

للرجوع (الصورة التي يعمل بها الجهاز فعلاً — خط الأساس المُعاد):

```bash
fastboot flash vendor_boot_a device/xiaomi/rodin/prebuilt/vendor_boot_stock.img
```

> خط الأساس الحالي = `OS3.0.8.0.WOJMIXM` (`f3e58747…`، وحداته 6.6.89) حسب طلبك.
> لو تكرّر البوتلوب فالمتوقع هو تعارض `vermagic` مع نواة الجهاز 6.6.118:
> أعد سحب الجزء من الفلاشة المثبّتة، أو اطلب نسخة مبنية على `d6921924…`
> (موجودة في `git show fd75634:device/xiaomi/rodin/prebuilt/vendor_boot_stock.img`).

## 5) أدوات التشخيص

```bash
# معلومات صورة (بدون أي تبعيات)
python3 device/xiaomi/rodin/tools/vendor_boot_tool.py info vendor_boot-rodin.img

# اختبار ذاتي: إعادة بناء الصورة الأصلية ومقارنتها
python3 device/xiaomi/rodin/tools/vendor_boot_tool.py rebuild \
    prebuilt/vendor_boot_stock.img /tmp/rt.img
cmp /tmp/rt.img prebuilt/vendor_boot_stock.img && echo "الأداة سليمة"
```

## تحذيرات أخيرة

* **لا تتجاوز 62,000,000 بايت للـ ramdisk المشترك** (platform + recovery مضغوطين).
  تجاوزه = بوتلوب فوري بلا رسالة؛ السكربت يرفض البناء في هذه الحالة. قطعة
  الـplatform تُنقل كما هي من الفيرموير وتُضغط `zstd -19` (~17.35 ميجا بدل
  29.2)، فتبقى المساحة الكافية لقطعة الاسترجاع.
* **لا تجعل ملفات الشجرة تحجب ملفات الـplatform**: قطعة الاسترجاع تُفكّ فوق
  قطعة الـplatform، فأي `first_stage_ramdisk/fstab.mt6899` فيها يحلّ محل جدول
  الفيرموير (فيه `mi_ext` والـoverlays و`avb_keys`) ويتوقف الجهاز عند اللوجو.
  الشجرة تثبّت جدولها باسم `fstab.emmc` فقط، والسكربت يرفض غير ذلك.
* **لا توقّع بمفتاح** — الصورة الأصلية `algorithm NONE`؛ التوقيع بمفتاح اختبار
  يغيّر شكل vbmeta (2112 بدل 704 بايت) وهذا ما لا يعرفه البوت لودر.
* الفلاش على جهاز **مفتوح البوت لودر** فقط.
* لا تفلش `recovery.img` — الاسترجاع يسكن في `vendor_boot` على هذا اللوح.
* أول إقلاع قد يفشل؛ لا تحذف `vendor_boot_stock.img` أبداً.
