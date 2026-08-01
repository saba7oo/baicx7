@echo off
set "LUXSELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -Command "$m='#PS'+'START'; $c=[IO.File]::ReadAllText($env:LUXSELF,[Text.Encoding]::UTF8); $i=$c.IndexOf($m); if($i -lt 0){[void][Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms');[Windows.Forms.MessageBox]::Show('This file is damaged - download it again.');exit 1}; iex $c.Substring($i+$m.Length)"
exit /b
#PSSTART
# =============================================================================
#  LuxDash Setup - guided installer for the BAIC X7 (Qinggan C3005H) head unit
# =============================================================================
#  ONE FILE. Double-click it. It downloads everything else it needs.
#
#  The batch header above re-launches this same file through PowerShell, so the
#  rest of the file is PowerShell and never seen by cmd.exe. Keep the first four
#  lines ASCII-only and CRLF - cmd.exe reads a .bat by byte offset and LF-only
#  line endings eat the first character of every line.
#
#  What it does, in the order the user walks through it:
#    language -> fetch adb + the app -> connect the unit -> read its state ->
#    choose a plan -> Wi-Fi -> (optional) move Android to the 16 GB partition ->
#    install + configure -> verify.
#
#  Everything destructive is gated behind a measured precondition check and an
#  explicit typed confirmation. Nothing is claimed to have worked without being
#  read back from the unit.
# =============================================================================

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# The batch header leaves a console window behind it. Hide it - the owner of a
# car should see one clean window, not a terminal.
Add-Type -Namespace Lux -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("shcore.dll")]   public static extern int SetProcessDpiAwareness(int v);
'@
try { [void][Lux.Native]::SetProcessDpiAwareness(1) } catch { }
try { [void][Lux.Native]::ShowWindow([Lux.Native]::GetConsoleWindow(), 0) } catch { }

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------
$script:Lang     = 'en'
$script:Root     = Join-Path $env:LOCALAPPDATA 'LuxDash'
$script:Adb      = $null
$script:Serial   = $null
$script:Apk      = $null
$script:Model    = $null          # local ggml-base.bin if we can find one
$script:Plan     = 'install'      # install | storage | undo
$script:Info     = @{}
$script:Gates    = @{}
$script:BackupTo = [Environment]::GetFolderPath('Desktop')
$script:Busy     = $false
$script:LastOut  = ''

if (-not (Test-Path $script:Root)) { New-Item -ItemType Directory -Path $script:Root -Force | Out-Null }
$script:LogFile = Join-Path $script:Root ('setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

$PKG      = 'com.cardash.dashboard'
$ACT      = "$PKG/.lux.LuxActivity"
$HOME_ACT = "$PKG/.lux.HomeStubActivity"
$LISTENER = "$PKG/$PKG.DashboardNotificationListener"
$INAND    = '/inand/cardash'
# Pinned to the 'app' channel tag, NOT /releases/latest/. "Latest" means the most
# recently created release of ANY kind, so uploading the voice model on
# 2026-07-25 silently made this URL 404 for every fresh install. The 'app' tag is
# a moving pointer that only ever holds the current dashboard build.
$APK_URL  = 'https://github.com/saba7oo/baicx7/releases/download/app/cardashboard-car-release.apk'
$PT_URL   = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'

# ----------------------------------------------------------------------------
# Text (en / ar)
# ----------------------------------------------------------------------------
$script:T = @{}
function Def($k, $en, $ar) { $script:T[$k] = @{ en = $en; ar = $ar } }
function L($k) { if ($script:T.ContainsKey($k)) { $script:T[$k][$script:Lang] } else { $k } }

Def 'app'        'LuxDash Setup'                       'إعداد لوحة LuxDash'
Def 'next'       'Next'                                'التالي'
Def 'back'       'Back'                                'السابق'
Def 'close'      'Close'                               'إغلاق'
Def 'finish'     'Finish'                              'إنهاء'
Def 'details'    'Show details'                        'عرض التفاصيل'
Def 'retry'      'Check again'                         'إعادة الفحص'
Def 'working'    'Working...'                          'جارٍ التنفيذ...'
Def 'ready'      'Ready'                               'جاهز'

Def 's.lang'     'Language'                            'اللغة'
Def 's.tools'    'Tools'                               'الأدوات'
Def 's.connect'  'Connect'                             'التوصيل'
Def 's.check'    'Check the unit'                      'فحص الجهاز'
Def 's.plan'     'Choose'                              'الاختيار'
Def 's.wifi'     'Wi-Fi'                               'الواي فاي'
Def 's.storage'  'Storage upgrade'                     'توسيع التخزين'
Def 's.install'  'Install'                             'التثبيت'
Def 's.done'     'Done'                                'الانتهاء'

# --- language page
Def 'lang.t'     'Choose your language'                'اختر لغتك'
Def 'lang.b'     'You can change it later by restarting this program.' 'يمكنك تغييرها لاحقاً بإعادة تشغيل البرنامج.'

# --- welcome
Def 'w.t'        'Welcome'                             'أهلاً بك'
Def 'w.1'        'This program installs the LuxDash dashboard on your car screen and sets the unit up for it.' 'هذا البرنامج يثبّت لوحة LuxDash على شاشة سيارتك ويهيّئ الجهاز للعمل بها.'
Def 'w.2'        'You need: this laptop, a USB cable to the head unit, and an internet connection for the first run.' 'تحتاج إلى: هذا اللابتوب، وكابل USB موصول بشاشة السيارة، واتصال إنترنت في أول تشغيل.'
Def 'w.3'        'Nothing is changed on your car until you confirm it. Every step is checked and reported.' 'لن يتغيّر أي شيء في سيارتك قبل أن تؤكّد. كل خطوة تُفحص ويُعرض ناتجها.'
Def 'w.4'        'Park the car safely and keep the engine running or the unit powered for the whole process.' 'أوقف السيارة بأمان وأبقِ المحرك دائراً أو الجهاز موصولاً بالكهرباء طوال العملية.'
Def 'w.warn'     'This software is not made by BAIC. You are modifying your own head unit at your own risk.' 'هذا البرنامج ليس من إنتاج BAIC. أنت تعدّل جهازك على مسؤوليتك الخاصة.'

# --- tools
Def 't.t'        'Getting the tools'                   'تجهيز الأدوات'
Def 't.b'        'A one-time download of the Android USB tools and the dashboard app. They are kept on this laptop so the next run is instant.' 'تنزيل لمرة واحدة لأدوات أندرويد وتطبيق اللوحة. تُحفظ على هذا اللابتوب ليكون التشغيل القادم فورياً.'
Def 't.adb'      'Android USB tools (adb)'             'أدوات أندرويد عبر USB‏ (adb)'
Def 't.apk'      'LuxDash app'                         'تطبيق LuxDash'
Def 't.model'    'Arabic voice model (optional)'       'ملف الصوت العربي (اختياري)'
Def 't.get'      'Download now'                        'نزّل الآن'
Def 't.browse'   'Choose a file on this laptop...'     'اختر ملفاً من هذا اللابتوب...'
Def 't.found'    'ready'                               'جاهز'
Def 't.missing'  'not downloaded yet'                  'لم يُنزَّل بعد'
Def 't.skip'     'skipped - the app downloads it itself on first boot' 'تم التخطي - التطبيق ينزّله بنفسه عند أول تشغيل'
Def 't.fail'     'Download failed. Check the internet connection, or pick the file manually.' 'فشل التنزيل. تحقق من الإنترنت، أو اختر الملف يدوياً.'

# --- connect
Def 'c.t'        'Connect the head unit'               'وصّل شاشة السيارة'
Def 'c.1'        'On the car screen: Settings -> About -> tap "Build number" seven times -> Developer options -> turn on "USB debugging".' 'على شاشة السيارة: الإعدادات ← حول الجهاز ← اضغط على «رقم الإصدار» سبع مرات ← خيارات المطوّر ← فعّل «تصحيح أخطاء USB».'
Def 'c.2'        'In Chinese: 设置 -> 关于本机 -> 版本号 (x7) -> 开发者选项 -> USB调试' 'بالصينية: 设置 ← 关于本机 ← 版本号 (سبع مرات) ← 开发者选项 ← USB调试'
Def 'c.3'        'Then plug the USB cable from this laptop into the unit and tap "Allow" on the screen.' 'ثم صِل كابل USB من اللابتوب إلى الجهاز واضغط «السماح» على الشاشة.'
Def 'c.wait'     'Waiting for the head unit...'        'في انتظار الجهاز...'
Def 'c.unauth'   'Found the unit, but it has not been allowed yet. Tap "Allow USB debugging" on the car screen.' 'تم العثور على الجهاز لكن لم يُسمح له بعد. اضغط «السماح بتصحيح أخطاء USB» على شاشة السيارة.'
Def 'c.many'     'More than one device is connected. Unplug everything except the head unit.' 'يوجد أكثر من جهاز موصول. افصل كل شيء ما عدا شاشة السيارة.'
Def 'c.ok'       'Connected.'                          'تم الاتصال.'

# --- diagnose
Def 'd.t'        'What is on the unit now'             'الوضع الحالي للجهاز'
Def 'd.b'        'Read directly from your unit. Nothing has been changed.' 'مقروء مباشرة من جهازك. لم يتغيّر أي شيء.'
Def 'd.model'    'Head unit'                           'الجهاز'
Def 'd.android'  'Android'                             'أندرويد'
Def 'd.slot'     'Active system'                       'النظام النشط'
Def 'd.storage'  'Android storage'                     'مساحة أندرويد'
Def 'd.dash'     'LuxDash installed'                   'LuxDash مثبّت'
Def 'd.none'     'not installed'                       'غير مثبّت'
Def 'd.swapped'  'Storage upgrade already applied'     'توسيع التخزين مطبَّق مسبقاً'
Def 'd.yes'      'yes'                                 'نعم'
Def 'd.no'       'no'                                  'لا'
Def 'd.full'     'Your Android storage is nearly full. The storage upgrade below is recommended.' 'مساحة أندرويد شبه ممتلئة. يُنصح بتوسيع التخزين أدناه.'
Def 'd.roomy'    'Storage is fine. You do not need the storage upgrade.' 'المساحة جيدة. لا تحتاج إلى توسيع التخزين.'

# --- plan
Def 'p.t'        'What do you want to do?'             'ماذا تريد أن تفعل؟'
Def 'p.install'  'Install or update LuxDash'           'تثبيت أو تحديث LuxDash'
Def 'p.installb' 'Safe. Keeps your apps and settings. Takes about 5 minutes and reboots the unit once.' 'آمن. يحافظ على تطبيقاتك وإعداداتك. يستغرق نحو 5 دقائق ويعيد تشغيل الجهاز مرة واحدة.'
Def 'p.storage'  'Storage upgrade, then install'       'توسيع التخزين ثم التثبيت'
Def 'p.storageb' 'Moves Android from the 4 GB partition to the 16 GB one. ERASES EVERYTHING on the system it switches to. About an hour.' 'ينقل أندرويد من قسم 4 غيغابايت إلى قسم 16 غيغابايت. يمسح كل شيء على النظام الذي ينتقل إليه. نحو ساعة.'
Def 'p.undo'     'Undo - bring the factory look back'  'التراجع - إعادة الشكل الأصلي'
Def 'p.undob'    'Re-enables the vendor status bar, launcher and radio. Does not delete anything.' 'يعيد تفعيل شريط الحالة والقائمة والراديو الأصلية. لا يحذف شيئاً.'
Def 'p.locked'   'Not available on this unit - see the checks below.' 'غير متاح على هذا الجهاز - راجع الفحوصات أدناه.'

# --- wifi
Def 'f.t'        'Wi-Fi on the unit'                   'الواي فاي على الجهاز'
Def 'f.b'        'The dashboard uses Wi-Fi for maps, weather and the app store. This is optional but recommended.' 'تستخدم اللوحة الواي فاي للخرائط والطقس ومتجر التطبيقات. اختياري لكن يُنصح به.'
Def 'f.on'       'Wi-Fi is on.'                        'الواي فاي مُفعّل.'
Def 'f.off'      'Wi-Fi is off.'                       'الواي فاي مغلق.'
Def 'f.enable'   'Turn Wi-Fi on'                       'تشغيل الواي فاي'
Def 'f.open'     'Open Wi-Fi settings on the car screen' 'افتح إعدادات الواي فاي على شاشة السيارة'
Def 'f.pick'     'Pick your network and type its password on the car screen, then come back here.' 'اختر شبكتك واكتب كلمة المرور على شاشة السيارة ثم عُد إلى هنا.'
Def 'f.net'      'Connected to'                        'متصل بـ'

# --- storage: gates
Def 'g.t'        'Safety checks'                       'فحوصات الأمان'
Def 'g.b'        'All five must pass. Each one is measured on your unit right now - none is assumed.' 'يجب أن تنجح الخمسة جميعاً. كل فحص يُقاس على جهازك الآن - لا شيء مفترض.'
Def 'g.1'        'Bootloader is unlocked'              'محمّل الإقلاع غير مقفل'
Def 'g.1x'       'A locked unit will refuse to boot the modified system, and there would be no way back.' 'الجهاز المقفل سيرفض إقلاع النظام المعدّل، ولن يكون هناك طريق للرجوع.'
Def 'g.2'        'Unit has two systems (A and B)'      'الجهاز يحتوي على نظامين (A و B)'
Def 'g.2x'       'The spare system is what you switch back to if anything goes wrong.' 'النظام الاحتياطي هو ما سترجع إليه إذا حدث أي خطأ.'
Def 'g.3'        'The spare system is complete and bootable' 'النظام الاحتياطي كامل وقابل للإقلاع'
Def 'g.3x'       'Verified by mounting it and comparing its build to the running one.' 'تم التحقق بتركيبه ومقارنة إصداره بالنظام العامل.'
Def 'g.4'        'The 16 GB partition holds no vendor maps' 'قسم 16 غيغابايت لا يحتوي خرائط المصنع'
Def 'g.4x'       'The upgrade erases that partition. Offline vendor maps would be lost.' 'التوسيع يمسح ذلك القسم. ستُفقد خرائط المصنع دون اتصال.'
Def 'g.5'        'Not already upgraded'                'لم يتم التوسيع مسبقاً'
Def 'g.pass'     'PASS'                                'ناجح'
Def 'g.fail'     'FAIL'                                'فاشل'
Def 'g.stop'     'One or more checks failed. The storage upgrade is not safe on this unit and is blocked.' 'فشل فحص أو أكثر. توسيع التخزين غير آمن على هذا الجهاز وتم منعه.'
Def 'g.go'       'All checks passed.'                  'نجحت جميع الفحوصات.'

# --- storage: cost
Def 'k.t'        'What you are giving up'              'ما الذي ستفقده'
Def 'k.1'        'The system you switch to starts completely empty - no apps, no settings, no Wi-Fi passwords. Everything is reinstalled.' 'النظام الذي ستنتقل إليه سيبدأ فارغاً تماماً - بلا تطبيقات ولا إعدادات ولا كلمات مرور واي فاي. سيُعاد تثبيت كل شيء.'
Def 'k.2'        'Vendor offline maps become impossible while the upgrade is in place.' 'ستصبح خرائط المصنع دون اتصال غير ممكنة طالما التوسيع مطبَّق.'
Def 'k.3'        'In the recovery menu afterwards, item 7 and item 8 swap meaning. Item 8 will then erase your Android.' 'في قائمة الاسترداد لاحقاً، يتبادل البندان 7 و 8 معناهما. البند 8 سيمسح أندرويد لديك.'
Def 'k.4'        'Your old data is not deleted - it stays on the small partition and comes back if you switch systems again.' 'بياناتك القديمة لا تُحذف - تبقى على القسم الصغير وتعود إذا رجعت للنظام الآخر.'
Def 'k.5'        'A future dealer software update can silently undo this. Not a failure, but it would look confusing.' 'تحديث لاحق من الوكيل قد يلغي هذا تلقائياً. ليس عطلاً، لكنه قد يبدو مربكاً.'
Def 'k.ack'      'I have read this and I want to continue' 'قرأت ما سبق وأريد المتابعة'
Def 'k.type'     'Type UPGRADE to continue'            'اكتب UPGRADE للمتابعة'

# --- storage: backup
Def 'b.t'        'Back up first'                       'خذ نسخة احتياطية أولاً'
Def 'b.b'        'Saves your dashboard settings and a list of your installed apps to this laptop.' 'يحفظ إعدادات لوحتك وقائمة تطبيقاتك المثبّتة على هذا اللابتوب.'
Def 'b.where'    'Save to'                             'الحفظ في'
Def 'b.choose'   'Change folder...'                    'تغيير المجلد...'
Def 'b.run'      'Back up now'                         'ابدأ النسخ الاحتياطي'
Def 'b.done'     'Backup saved.'                       'تم حفظ النسخة الاحتياطية.'
Def 'b.skip'     'LuxDash is not installed yet, so there is nothing to back up.' 'LuxDash غير مثبّت، لذا لا يوجد ما يُنسخ.'

# --- storage: edit
Def 'e.t'        'Preparing the spare system'          'تهيئة النظام الاحتياطي'
Def 'e.b'        'This edits two lines of a text file on the system you are NOT running. The system you are using now is not touched and stays bootable.' 'يعدّل هذا سطرين في ملف نصي على النظام الذي لا تعمل عليه الآن. النظام الذي تستخدمه لا يُمس ويبقى قابلاً للإقلاع.'
Def 'e.run'      'Apply the change'                    'طبّق التعديل'
Def 'e.ok'       'Applied. A copy of the original file was saved to your backup folder.' 'تم التطبيق. حُفظت نسخة من الملف الأصلي في مجلد النسخ الاحتياطي.'
Def 'e.err'      'The change was NOT applied. Nothing on your unit was modified.' 'لم يُطبَّق التعديل. لم يتغيّر شيء في جهازك.'
Def 'e.before'   'Before'                              'قبل'
Def 'e.after'    'After'                               'بعد'

# --- storage: recovery
Def 'r.t'        'Now do two things on the car screen' 'الآن نفّذ خطوتين على شاشة السيارة'
Def 'r.b'        'This part cannot be done from the laptop. Follow it exactly, in this order.' 'هذا الجزء لا يمكن تنفيذه من اللابتوب. اتّبعه بالضبط وبهذا الترتيب.'
Def 'r.boot'     'Reboot the unit into the recovery menu'  'أعد تشغيل الجهاز إلى قائمة الاسترداد'
Def 'r.bootb'    'If the unit boots normally instead, use your unit''s own key combination to reach recovery.' 'إذا أقلع الجهاز بشكل طبيعي، استخدم تركيبة الأزرار الخاصة بجهازك للوصول إلى قائمة الاسترداد.'
Def 'r.i8'       'Choose item 8'                       'اختر البند 8'
Def 'r.i8b'      'Format the map partition. The unit reboots by itself afterwards.' 'تهيئة قسم الخرائط. سيعيد الجهاز تشغيل نفسه بعدها.'
Def 'r.i11'      'Go back into recovery, choose item 11' 'ادخل قائمة الاسترداد مرة أخرى واختر البند 11'
Def 'd.slot'     'Your 16 GB layout lives on this boot slot. If this slot ever fails to boot, the unit re-flashes it — the layout goes with it. Keep risky system changes off it.' 'تخطيط الـ16 غيغابايت مرتبط بهذه الشريحة. إذا فشل إقلاعها، يعيد الجهاز تثبيتها ويضيع التخطيط. تجنّب التعديلات النظامية الخطرة عليها.'
Def 'r.i11b'     'Switch to the backup system. Confirm with 是 (yes), not 否 (no).' 'التبديل إلى النظام الاحتياطي. أكّد بـ 是 (نعم) وليس 否 (لا).'
Def 'r.did'      'I have done both steps'              'أنجزت الخطوتين'

# --- storage: wait
Def 'x.t'        'First start on the new system'       'أول تشغيل على النظام الجديد'
Def 'x.1'        'This first boot is slow - several minutes - and comes up in Chinese with the factory launcher. Both are normal.' 'أول إقلاع بطيء - عدة دقائق - ويظهر بالصينية مع واجهة المصنع. كلاهما طبيعي.'
Def 'x.2'        'USB debugging was erased with the old data, so turn it on again:' 'مُسح تصحيح أخطاء USB مع البيانات القديمة، لذا فعّله من جديد:'
Def 'x.wait'     'Waiting for the unit...'             'في انتظار الجهاز...'
Def 'x.ok'       'The unit is back and the upgrade took effect.' 'عاد الجهاز ونجح التوسيع.'
Def 'x.bad'      'The unit is back, but Android is still on the small partition. See the details.' 'عاد الجهاز، لكن أندرويد ما زال على القسم الصغير. راجع التفاصيل.'

# --- install
Def 'i.t'        'Installing'                          'جارٍ التثبيت'
Def 'i.b'        'The unit reboots once during this. Do not unplug the cable.' 'سيعيد الجهاز التشغيل مرة واحدة أثناء ذلك. لا تفصل الكابل.'
Def 'i.run'      'Start'                               'ابدأ'
Def 'i.s1'       'Installing the app'                  'تثبيت التطبيق'
Def 'i.s2'       'Copying the voice model'             'نسخ ملف الصوت'
Def 'i.s3'       'Removing the factory status bar'     'إزالة شريط الحالة الأصلي'
Def 'i.s4'       'Turning off the boot voice and the extra launchers' 'إيقاف صوت الإقلاع والقوائم الإضافية'
Def 'i.s5'       'Making boot fast'                    'تسريع الإقلاع'
Def 'i.s6'       'Making LuxDash the home screen'      'جعل LuxDash الشاشة الرئيسية'
Def 'i.s7'       'Rebooting the unit'                  'إعادة تشغيل الجهاز'
Def 'i.s8'       'Re-applying what the first boot undoes' 'إعادة تطبيق ما يلغيه أول إقلاع'
Def 'i.s9'       'Checking the result'                 'التحقق من النتيجة'

# --- verify / done
Def 'v.t'        'Result'                              'النتيجة'
Def 'v.app'      'App installed'                       'التطبيق مثبّت'
Def 'v.bar'      'Factory status bar removed'          'شريط الحالة الأصلي مُزال'
Def 'v.launch'   'Factory launcher off'                'قائمة المصنع مغلقة'
Def 'v.login'    'Login screen skipped'                'شاشة تسجيل الدخول متخطّاة'
Def 'v.home'     'LuxDash is the home screen'          'LuxDash هي الشاشة الرئيسية'
Def 'v.free'     'Split screen enabled'                'تقسيم الشاشة مُفعّل'
Def 'v.voice'    'Voice model'                         'ملف الصوت'
Def 'v.data'     'Android storage'                     'مساحة أندرويد'
Def 'v.allok'    'Everything worked.'                  'نجح كل شيء.'
Def 'v.some'     'Finished, but some items did not take. The list above shows which.' 'انتهى، لكن بعض البنود لم تُطبَّق. القائمة أعلاه توضّح أيها.'
Def 'v.log'      'Save the report...'                  'حفظ التقرير...'
Def 'v.restore'  'Restore my old settings from backup' 'استعادة إعداداتي القديمة من النسخة'

# --- undo
Def 'u.t'        'Restoring the factory look'          'إعادة الشكل الأصلي'
Def 'u.run'      'Restore now'                         'استعد الآن'
Def 'u.ok'       'Restored. The unit needs a reboot for the status bar to come back.' 'تمت الاستعادة. يحتاج الجهاز إعادة تشغيل ليعود شريط الحالة.'
Def 'u.reboot'   'Reboot the unit now'                 'أعد تشغيل الجهاز الآن'

Def 'err.adb'    'Lost the connection to the head unit. Check the cable and try again.' 'انقطع الاتصال بالجهاز. تحقق من الكابل وحاول مجدداً.'

# ----------------------------------------------------------------------------
# Look
# ----------------------------------------------------------------------------
$C_BG    = [Drawing.Color]::FromArgb(16, 20, 24)
$C_PANEL = [Drawing.Color]::FromArgb(23, 28, 34)
$C_CARD  = [Drawing.Color]::FromArgb(30, 36, 44)
$C_TEXT  = [Drawing.Color]::FromArgb(232, 237, 242)
$C_MUTE  = [Drawing.Color]::FromArgb(147, 161, 174)
$C_GOLD  = [Drawing.Color]::FromArgb(227, 179, 65)
$C_OK    = [Drawing.Color]::FromArgb(63, 185, 80)
$C_WARN  = [Drawing.Color]::FromArgb(210, 153, 34)
$C_ERR   = [Drawing.Color]::FromArgb(248, 81, 73)

function F($size, $bold) {
    $st = if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    New-Object Drawing.Font('Segoe UI', $size, $st)
}

# Every coordinate in this file is written in 96-dpi "logical" units and scaled
# here. Windows is left out of it (AutoScaleMode = None) because auto-scaling a
# form whose children are positioned absolutely clips them: on a 125% display
# the first build put half of the language buttons behind the sidebar.
$script:S = 1.0
try {
    $g0 = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:S = $g0.DpiX / 96.0
    $g0.Dispose()
} catch { $script:S = 1.0 }
function U($n) { [int][math]::Round(([double]$n) * $script:S) }
function V($n) { [int][math]::Round(([double]$n) / $script:S) }
function PT($x, $y) { New-Object Drawing.Point((U $x), (U $y)) }
function SZ($w, $h) { New-Object Drawing.Size((U $w), (U $h)) }

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
function Log($msg, $kind) {
    if ($null -eq $msg) { return }
    $line = '[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $(if ($kind) { "$kind " } else { '' }), $msg
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

# ----------------------------------------------------------------------------
# adb plumbing
# ----------------------------------------------------------------------------
function Adb {
    param([string[]]$A, [switch]$NoDevice, [switch]$Quiet)
    if (-not $script:Adb) { return '' }
    $full = @()
    if (-not $NoDevice -and $script:Serial) { $full += @('-s', $script:Serial) }
    $full += $A
    if (-not $Quiet) { Log ('adb ' + ($full -join ' ')) '>' }
    $out = ''
    try { $out = (& $script:Adb @full 2>&1 | Out-String) } catch { $out = "$_" }
    $script:LastOut = $out
    if (-not $Quiet -and $out.Trim()) { Log $out.Trim() '|' }
    return $out
}

function Sh($cmd) { return (Adb @('shell', $cmd)) }

# Push a multi-line shell script and run it. Removes every quoting problem
# between Windows, adb and the device shell, and lets the device-side logic be
# readable. Written LF-only - a CR would make the device shell choke.
function ShFile($body) {
    $tmp = Join-Path $env:TEMP 'luxdash.sh'
    $txt = ($body -replace "`r`n", "`n")
    [IO.File]::WriteAllText($tmp, $txt, (New-Object Text.UTF8Encoding($false)))
    Adb @('push', $tmp, '/data/local/tmp/luxdash.sh') | Out-Null
    $r = Adb @('shell', 'sh /data/local/tmp/luxdash.sh')
    Remove-Item $tmp -ErrorAction SilentlyContinue
    return $r
}

# key=value output -> hashtable
function ParseKV($text) {
    $h = @{}
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z0-9_]+)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() }
    }
    return $h
}

function HumanKB($kb) {
    $n = 0
    if (-not [int64]::TryParse("$kb", [ref]$n)) { return '?' }
    if ($n -ge 1048576) { return ('{0:N1} GB' -f ($n / 1048576.0)) }
    return ('{0:N0} MB' -f ($n / 1024.0))
}

# ----------------------------------------------------------------------------
# Form
# ----------------------------------------------------------------------------
$Form = New-Object Windows.Forms.Form
$Form.Text = 'LuxDash Setup'
$Form.Size = (SZ 1000 700)
$Form.AutoScaleMode = 'None'
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'FixedSingle'
$Form.MaximizeBox = $false
$Form.BackColor = $C_BG
$Form.ForeColor = $C_TEXT
$Form.Font = (F 10 $false)

$Head = New-Object Windows.Forms.Panel
$Head.Dock = 'Top'; $Head.Height = (U 74); $Head.BackColor = $C_PANEL

$HeadTitle = New-Object Windows.Forms.Label
$HeadTitle.Location = (PT 24 14)
$HeadTitle.Size = (SZ 600 30)
$HeadTitle.Font = (F 15 $true); $HeadTitle.ForeColor = $C_GOLD
$Head.Controls.Add($HeadTitle)

$HeadSub = New-Object Windows.Forms.Label
$HeadSub.Location = (PT 26 44)
$HeadSub.Size = (SZ 700 20)
$HeadSub.ForeColor = $C_MUTE
$Head.Controls.Add($HeadSub)

$Foot = New-Object Windows.Forms.Panel
$Foot.Dock = 'Bottom'; $Foot.Height = (U 62); $Foot.BackColor = $C_PANEL

$BtnNext = New-Object Windows.Forms.Button
$BtnNext.Size = (SZ 150 38)
$BtnNext.Location = (PT 820 12)
$BtnNext.FlatStyle = 'Flat'; $BtnNext.BackColor = $C_GOLD
$BtnNext.ForeColor = [Drawing.Color]::FromArgb(20, 20, 20)
$BtnNext.Font = (F 10 $true)
$Foot.Controls.Add($BtnNext)

$BtnBack = New-Object Windows.Forms.Button
$BtnBack.Size = (SZ 110 38)
$BtnBack.Location = (PT 698 12)
$BtnBack.FlatStyle = 'Flat'; $BtnBack.BackColor = $C_CARD; $BtnBack.ForeColor = $C_TEXT
$Foot.Controls.Add($BtnBack)

# Anchor='Right' is evaluated against the parent's size at the moment it is set.
# These buttons are created before the footer is docked, so the anchor resolved
# against a default-sized panel and pushed Next clean off the window. Position
# them explicitly instead, whenever the footer has a real width.
function LayoutFoot() {
    $w = $Foot.ClientSize.Width
    if ($w -lt (U 400)) { return }
    if ($script:Lang -eq 'ar') {
        # Forward is leftward in Arabic.
        $BtnNext.Location = New-Object Drawing.Point((U 24), (U 12))
        $BtnBack.Location = New-Object Drawing.Point(($BtnNext.Right + (U 12)), (U 12))
        $ChkLog.Location  = New-Object Drawing.Point(($w - (U 24) - $ChkLog.Width), (U 20))
        $ChkLog.RightToLeft = 'Yes'
        $Bar.Location     = New-Object Drawing.Point(($w - (U 274) - $Bar.Width), (U 22))
    } else {
        $BtnNext.Location = New-Object Drawing.Point(($w - (U 24) - $BtnNext.Width), (U 12))
        $BtnBack.Location = New-Object Drawing.Point(($BtnNext.Left - (U 12) - $BtnBack.Width), (U 12))
        $ChkLog.Location  = New-Object Drawing.Point((U 24), (U 20))
        $ChkLog.RightToLeft = 'No'
        $Bar.Location     = New-Object Drawing.Point((U 250), (U 22))
    }
}
$Foot.Add_Resize({ LayoutFoot })

$ChkLog = New-Object Windows.Forms.CheckBox
$ChkLog.Location = (PT 24 20)
$ChkLog.Size = (SZ 220 24)
$ChkLog.ForeColor = $C_MUTE
$Foot.Controls.Add($ChkLog)

$Bar = New-Object Windows.Forms.ProgressBar
$Bar.Location = (PT 250 22)
$Bar.Size = (SZ 420 16)
$Bar.Style = 'Marquee'; $Bar.Visible = $false
$Foot.Controls.Add($Bar)

$script:LogBox = New-Object Windows.Forms.RichTextBox
$script:LogBox.Dock = 'Bottom'; $script:LogBox.Height = (U 170)
$script:LogBox.BackColor = [Drawing.Color]::FromArgb(12, 15, 18)
$script:LogBox.ForeColor = $C_MUTE
$script:LogBox.Font = New-Object Drawing.Font('Consolas', 8.5)
$script:LogBox.ReadOnly = $true; $script:LogBox.Visible = $false
$script:LogBox.BorderStyle = 'None'

$Side = New-Object Windows.Forms.Panel
$Side.Dock = 'Left'; $Side.Width = (U 232); $Side.BackColor = $C_PANEL

$Content = New-Object Windows.Forms.Panel
$Content.Dock = 'Fill'; $Content.BackColor = $C_BG; $Content.AutoScroll = $true

# ORDER IS THE LAYOUT. WinForms docks children starting from the HIGHEST index,
# so the control added LAST claims its band first and ends up outermost. Adding
# the Fill panel last made it swallow the whole client area and the sidebar was
# simply painted on top of the page content. Outermost goes last.
$Form.Controls.Add($Content)      # innermost - gets whatever is left
$Form.Controls.Add($Side)
$Form.Controls.Add($script:LogBox)
$Form.Controls.Add($Foot)
$Form.Controls.Add($Head)         # outermost - full width across the top

$ChkLog.Add_CheckedChanged({ $script:LogBox.Visible = $ChkLog.Checked })

# ----------------------------------------------------------------------------
# Content builders. $script:y is the vertical cursor inside $Content.
# ----------------------------------------------------------------------------
function ClearContent() {
    $Content.Controls.Clear()
    $Content.AutoScrollPosition = (PT 0 0)
    $script:y = 28
}

function W($ctl, $h) {
    $Content.Controls.Add($ctl)
    $script:y += $h
    return $ctl
}

function Txt($text, $size, $bold, $color, $gap) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.Font = (F $size $bold)
    $l.ForeColor = $color
    $l.Location = (PT 34 $script:y)
    $l.Size = (SZ 660 10)
    $l.AutoSize = $false
    $l.MaximumSize = (SZ 660 0)
    $l.AutoSize = $true
    if ($script:Lang -eq 'ar') { $l.RightToLeft = 'Yes' }
    [void](W $l 0)
    $script:y += (V $l.Height) + $gap
    # Deliberately returns nothing: these are called as bare statements, and a
    # returned Control would be formatted onto the console.
}

function H1($t) { Txt $t 16 $true $C_TEXT 10 }
function P($t)  { Txt $t 10 $false $C_MUTE 12 }
function B($t)  { Txt $t 10 $false $C_TEXT 12 }

function Bullet($t, $color) {
    if (-not $color) { $color = $C_TEXT }
    $mark = if ($script:Lang -eq 'ar') { '‏•  ' } else { '•  ' }
    Txt ($mark + $t) 10 $false $color 8
}

function Gap($h) { $script:y += $h }

function Card($h) {
    $p = New-Object Windows.Forms.Panel
    $p.Location = (PT 34 $script:y)
    $p.Size = (SZ 668 $h)
    $p.BackColor = $C_CARD
    [void](W $p ($h + 14))
    return $p
}

function Btn($text, $x, $y, $w, $parent, $primary) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Location = (PT $x $y)
    $b.Size = (SZ $w 34)
    $b.FlatStyle = 'Flat'
    if ($primary) {
        $b.BackColor = $C_GOLD; $b.ForeColor = [Drawing.Color]::FromArgb(20, 20, 20); $b.Font = (F 10 $true)
    } else {
        $b.BackColor = $C_CARD; $b.ForeColor = $C_TEXT
    }
    $parent.Controls.Add($b)
    return $b
}

# A labelled result row: name .......... value, coloured by state.
function Row($parent, $y, $name, $value, $state) {
    $a = New-Object Windows.Forms.Label
    $a.Text = $name; $a.Location = (PT 16 $y)
    $a.Size = (SZ 360 22); $a.ForeColor = $C_MUTE
    $parent.Controls.Add($a)
    $b = New-Object Windows.Forms.Label
    $b.Text = $value; $b.Location = (PT 380 $y)
    $b.Size = (SZ 272 22); $b.Font = (F 10 $true)
    $b.ForeColor = switch ($state) { 'ok' { $C_OK } 'err' { $C_ERR } 'warn' { $C_WARN } default { $C_TEXT } }
    $parent.Controls.Add($b)
}

function Busy($on, $text) {
    $script:Busy = $on
    $Bar.Visible = $on
    $BtnNext.Enabled = -not $on
    $BtnBack.Enabled = -not $on
    if ($text) { $HeadSub.Text = $text }
    [Windows.Forms.Application]::DoEvents()
}

# ----------------------------------------------------------------------------
# Sidebar
# ----------------------------------------------------------------------------
$script:Steps = @('s.lang', 's.tools', 's.connect', 's.check', 's.plan', 's.wifi', 's.storage', 's.install', 's.done')

function DrawSide($active) {
    $Side.Controls.Clear()
    $yy = 24
    for ($i = 0; $i -lt $script:Steps.Count; $i++) {
        $l = New-Object Windows.Forms.Label
        $done = $i -lt $active
        $mark = if ($done) { [char]0x2713 } elseif ($i -eq $active) { [char]0x25CF } else { [char]0x25CB }
        $l.Text = "$mark   " + (L $script:Steps[$i])
        $l.Location = (PT 20 $yy)
        $l.Size = (SZ 200 26)
        $l.Font = (F 10 ($i -eq $active))
        $l.ForeColor = if ($i -eq $active) { $C_GOLD } elseif ($done) { $C_OK } else { $C_MUTE }
        if ($script:Lang -eq 'ar') { $l.RightToLeft = 'Yes'; $l.TextAlign = 'MiddleRight' }
        $Side.Controls.Add($l)
        $yy += 34
    }
}

# ----------------------------------------------------------------------------
# Page machinery
# ----------------------------------------------------------------------------
$script:Pages = @('lang', 'welcome', 'tools', 'connect', 'diag', 'plan')
$script:Idx = 0
$script:OnNext = $null

function SetNav($nextText, $nextEnabled, $backVisible) {
    $BtnNext.Text = $nextText
    $BtnNext.Enabled = $nextEnabled
    $BtnBack.Visible = $backVisible
    $BtnBack.Text = (L 'back')
    LayoutFoot
}

function Render() {
    # Any page-owned polling timer belongs to the page that started it.
    if ($script:Timer) { $script:Timer.Stop(); $script:Timer.Dispose(); $script:Timer = $null }
    $script:OnNext = $null

    ClearContent
    $id = $script:Pages[$script:Idx]
    Log ("render '$id'  form=$($Form.ClientSize.Width)x$($Form.ClientSize.Height)" +
         "  side=$($Side.Width)  content=$($Content.Bounds)  scale=$script:S") '#'
    $HeadTitle.Text = (L 'app')
    $HeadSub.Text = ''
    $ChkLog.Text = (L 'details')
    $Side.Dock = $(if ($script:Lang -eq 'ar') { 'Right' } else { 'Left' })
    & ("Page_" + $id)
    MirrorPage
}

# Arabic layout is mirrored BY HAND.
#
# The obvious route - $Form.RightToLeftLayout = $true - is not survivable here:
# it recreates the form's window handle, and on this stack that is a hard native
# fault (the process vanishes with no .NET exception, even when the change is
# deferred out of the click handler with BeginInvoke). Confirmed by bisection:
# clicking English survived, clicking Arabic did not, and stderr was empty.
#
# So instead: flip the sidebar's Dock edge, reflect each child's Left about its
# parent's width, and set RightToLeft on the controls themselves. Setting that
# property on a CHILD is fine - only the Form's handle is fatal to recreate.
function MirrorPage() {
    $rtl = ($script:Lang -eq 'ar')
    $HeadTitle.TextAlign = $(if ($rtl) { 'MiddleRight' } else { 'MiddleLeft' })
    $HeadSub.TextAlign   = $(if ($rtl) { 'MiddleRight' } else { 'MiddleLeft' })
    $HeadTitle.Width = $Head.ClientSize.Width - (U 48)
    $HeadSub.Width   = $Head.ClientSize.Width - (U 52)
    LayoutFoot
    if ($rtl) { MirrorTree $Content }
}

function MirrorTree($parent) {
    foreach ($c in $parent.Controls) {
        if ($c.Dock -eq 'None') {
            $c.Left = $parent.ClientSize.Width - $c.Left - $c.Width
        }
        $c.RightToLeft = 'Yes'
        if ($c -is [Windows.Forms.Label] -and -not $c.AutoSize) { $c.TextAlign = 'TopRight' }
        if ($c.Controls.Count -gt 0) { MirrorTree $c }
    }
}

function Go($delta) {
    $n = $script:Idx + $delta
    if ($n -lt 0) { return }
    if ($n -ge $script:Pages.Count) { $Form.Close(); return }
    $script:Idx = $n
    Render
}

$BtnNext.Add_Click({
    if ($script:Busy) { return }
    if ($script:OnNext) { & $script:OnNext } else { Go 1 }
})
$BtnBack.Add_Click({ if (-not $script:Busy) { Go -1 } })

# Rebuild the remaining page list once the user has chosen a plan.
function SetPlan($plan) {
    $script:Plan = $plan
    $base = @('lang', 'welcome', 'tools', 'connect', 'diag', 'plan')
    switch ($plan) {
        'install' { $script:Pages = $base + @('wifi', 'install', 'done') }
        'storage' { $script:Pages = $base + @('gates', 'cost', 'backup', 'edit', 'recovery', 'wait', 'wifi', 'install', 'done') }
        'undo'    { $script:Pages = $base + @('undo') }
    }
}

# =============================================================================
# PAGES
# =============================================================================

function Page_lang() {
    DrawSide 0
    H1 'Language  /  اللغة'
    Gap 10
    $c = Card 130
    $en = Btn 'English' 40 34 240 $c $true
    $ar = Btn 'العربية' 340 34 240 $c $true
    $ar.Font = (F 12 $true)
    # Navigate AFTER this click has finished being dispatched - picking Arabic
    # flips the form to a mirrored layout, which recreates the window handle.
    $en.Add_Click({ $script:Lang = 'en'; $Form.BeginInvoke([Action] { Go 1 }) | Out-Null })
    $ar.Add_Click({ $script:Lang = 'ar'; $Form.BeginInvoke([Action] { Go 1 }) | Out-Null })
    Gap 6
    P (L 'lang.b')
    SetNav (L 'next') $false $false
}

function Page_welcome() {
    DrawSide 0
    H1 (L 'w.t')
    Gap 4
    B (L 'w.1')
    B (L 'w.2')
    B (L 'w.3')
    Gap 6
    Bullet (L 'w.4') $C_WARN
    Bullet (L 'w.warn') $C_WARN
    SetNav (L 'next') $true $true
}

function Page_tools() {
    DrawSide 1
    H1 (L 't.t')
    P (L 't.b')

    $c = Card 200
    $st = New-Object Windows.Forms.Label
    $st.Location = (PT 16 150)
    $st.Size = (SZ 640 40)
    $st.ForeColor = $C_MUTE
    $c.Controls.Add($st)

    $paint = {
        $script:Adb = Find-Adb
        $script:Apk = Find-Apk
        $script:Model = Find-Model
        Row $c 16  (L 't.adb')   $(if ($script:Adb)   { (L 't.found') } else { (L 't.missing') }) $(if ($script:Adb)   { 'ok' } else { 'warn' })
        Row $c 48  (L 't.apk')   $(if ($script:Apk)   { (L 't.found') } else { (L 't.missing') }) $(if ($script:Apk)   { 'ok' } else { 'warn' })
        Row $c 80  (L 't.model') $(if ($script:Model) { (L 't.found') } else { (L 't.skip') })    $(if ($script:Model) { 'ok' } else { 'warn' })
        $BtnNext.Enabled = ($script:Adb -and $script:Apk)
    }
    & $paint

    $get = Btn (L 't.get') 16 108 200 $c $true
    $get.Add_Click({
        Busy $true (L 'working')
        $failed = $false
        try {
            if (-not $script:Adb) { $st.Text = 'adb...'; [Windows.Forms.Application]::DoEvents(); Get-PlatformTools }
            if (-not $script:Apk) { $st.Text = 'LuxDash...'; [Windows.Forms.Application]::DoEvents(); Get-Apk }
        } catch {
            $failed = $true; Log "$_" '!'
        }
        Busy $false ''
        if ($failed) {
            # Re-render would wipe the message, so report in place and leave the
            # manual "choose a file" route visible.
            $st.Text = (L 't.fail'); $st.ForeColor = $C_ERR
            $script:Adb = Find-Adb; $script:Apk = Find-Apk
            $BtnNext.Enabled = [bool]($script:Adb -and $script:Apk)
        } else {
            Render
        }
    }.GetNewClosure())
    $br = Btn (L 't.browse') 232 108 260 $c $false
    $br.Add_Click({
        $d = New-Object Windows.Forms.OpenFileDialog
        $d.Filter = 'LuxDash app (*.apk)|*.apk'
        if ($d.ShowDialog() -eq 'OK') {
            Copy-Item $d.FileName (Join-Path $script:Root 'cardashboard-car-release.apk') -Force
            Render
        }
    })

    SetNav (L 'next') ($script:Adb -and $script:Apk) $true
}

function Page_connect() {
    DrawSide 2
    H1 (L 'c.t')
    Gap 2
    Bullet (L 'c.1')
    Bullet (L 'c.2')
    Bullet (L 'c.3')
    Gap 8
    $c = Card 88
    $st = New-Object Windows.Forms.Label
    $st.Location = (PT 16 16)
    $st.Size = (SZ 636 56)
    $st.Font = (F 11 $true)
    $st.Text = (L 'c.wait'); $st.ForeColor = $C_MUTE
    $c.Controls.Add($st)

    SetNav (L 'next') $false $true

    # Poll until exactly one authorised device shows up. A Timer keeps the UI
    # alive; the user can go Back at any time.
    $script:Timer = New-Object Windows.Forms.Timer
    $script:Timer.Interval = 1500
    $script:Timer.Add_Tick({
        if ($script:Busy) { return }
        $out = Adb @('devices') -NoDevice -Quiet
        $lines = @($out -split "`r?`n" | Where-Object { $_ -match '\S' -and $_ -notmatch 'List of devices' })
        $ok    = @($lines | Where-Object { $_ -match '^\s*(\S+)\s+device\s*$' })
        $unauth= @($lines | Where-Object { $_ -match 'unauthorized|offline' })
        if ($ok.Count -eq 1) {
            $script:Timer.Stop()
            $script:Serial = ($ok[0] -split '\s+')[0]
            $st.Text = (L 'c.ok') + "  ($script:Serial)"; $st.ForeColor = $C_OK
            Adb @('root') | Out-Null
            Adb @('wait-for-device') | Out-Null
            $BtnNext.Enabled = $true
        } elseif ($ok.Count -gt 1) {
            $st.Text = (L 'c.many'); $st.ForeColor = $C_ERR
        } elseif ($unauth.Count -gt 0) {
            $st.Text = (L 'c.unauth'); $st.ForeColor = $C_WARN
        } else {
            $st.Text = (L 'c.wait'); $st.ForeColor = $C_MUTE
        }
    })
    $script:Timer.Start()
}

function Page_diag() {
    DrawSide 3
    H1 (L 'd.t')
    P (L 'd.b')
    $c = Card 250
    Busy $true (L 'working')
    $script:Info = Read-Unit
    Busy $false ''

    $i = $script:Info
    $swapped = ($i['data_dev'] -and $i['byname_inand'] -and $i['data_dev'] -eq $i['byname_inand'])
    $freeKB = 0; [void][int64]::TryParse("$($i['data_free'])", [ref]$freeKB)
    $tight  = ($freeKB -gt 0 -and $freeKB -lt 1572864)   # < 1.5 GB

    Row $c 16  (L 'd.model')   ("$($i['model']) / $($i['device'])") 'plain'
    Row $c 46  (L 'd.android') "$($i['android'])" 'plain'
    Row $c 76  (L 'd.slot')    $(if ($i['slot'] -eq '_a') { 'A' } elseif ($i['slot'] -eq '_b') { 'B' } else { '?' }) 'plain'
    Row $c 106 (L 'd.storage') ((HumanKB $i['data_free']) + ' / ' + (HumanKB $i['data_total'])) $(if ($tight) { 'warn' } else { 'ok' })
    Row $c 136 (L 'd.dash')    $(if ($i['dash']) { $i['dash'] } else { (L 'd.none') }) $(if ($i['dash']) { 'ok' } else { 'plain' })
    Row $c 166 (L 'd.swapped') $(if ($swapped) { (L 'd.yes') } else { (L 'd.no') }) $(if ($swapped) { 'ok' } else { 'plain' })

    $n = New-Object Windows.Forms.Label
    $n.Location = (PT 16 202)
    $n.Size = (SZ 636 40)
    $n.ForeColor = $(if ($tight -and -not $swapped) { $C_WARN } else { $C_OK })
    $n.Text = $(if ($tight -and -not $swapped) { (L 'd.full') } else { (L 'd.roomy') })
    $c.Controls.Add($n)

    $script:Info['swapped'] = $swapped
    $script:Info['tight']   = $tight
    SetNav (L 'next') $true $true
}

function Page_plan() {
    DrawSide 4
    H1 (L 'p.t')
    Gap 4

    $mk = {
        param($title, $body, $plan, $enabled, $accent)
        $c = Card 96
        $t = New-Object Windows.Forms.Label
        $t.Text = $title; $t.Location = (PT 18 14)
        $t.Size = (SZ 500 26); $t.Font = (F 12 $true)
        $t.ForeColor = $(if ($enabled) { $accent } else { $C_MUTE })
        $c.Controls.Add($t)
        $b = New-Object Windows.Forms.Label
        $b.Text = $body; $b.Location = (PT 18 42)
        $b.Size = (SZ 490 44); $b.ForeColor = $C_MUTE
        $c.Controls.Add($b)
        $go = Btn (L 'next') 528 32 120 $c $enabled
        $go.Enabled = $enabled
        $go.Tag = $plan
        $go.Add_Click({ SetPlan $this.Tag; Go 1 }.GetNewClosure())
        return $c
    }

    [void](& $mk (L 'p.install') (L 'p.installb') 'install' $true $C_GOLD)

    $canStorage = -not $script:Info['swapped']
    $sb = if ($canStorage) { (L 'p.storageb') } else { (L 'd.swapped') }
    [void](& $mk (L 'p.storage') $sb 'storage' $canStorage $C_WARN)

    [void](& $mk (L 'p.undo') (L 'p.undob') 'undo' $true $C_MUTE)

    SetNav (L 'next') $false $true
}

function Page_wifi() {
    DrawSide 5
    H1 (L 'f.t')
    P (L 'f.b')
    $c = Card 150
    $st = New-Object Windows.Forms.Label
    $st.Location = (PT 16 16)
    $st.Size = (SZ 636 46); $st.Font = (F 11 $true)
    $c.Controls.Add($st)

    $refresh = {
        $on = (Sh 'settings get global wifi_on').Trim()
        $ssid = ''
        $d = Sh 'dumpsys wifi | grep -m1 "mWifiInfo SSID"'
        if ($d -match 'SSID:\s*"?([^",]+)') { $ssid = $Matches[1].Trim() }
        if ($on -match '1') {
            $st.Text = (L 'f.on') + $(if ($ssid -and $ssid -ne '<unknown ssid>') { "   " + (L 'f.net') + " $ssid" } else { '' })
            $st.ForeColor = $C_OK
        } else {
            $st.Text = (L 'f.off'); $st.ForeColor = $C_WARN
        }
    }
    Busy $true (L 'working'); & $refresh; Busy $false ''

    $en = Btn (L 'f.enable') 16 74 200 $c $true
    $en.Add_Click({ Busy $true (L 'working'); Sh 'svc wifi enable' | Out-Null; Start-Sleep -Milliseconds 1500; & $refresh; Busy $false '' }.GetNewClosure())
    $op = Btn (L 'f.open') 232 74 320 $c $false
    $op.Add_Click({ Sh 'am start -a android.settings.WIFI_SETTINGS' | Out-Null })
    $rf = Btn (L 'retry') 16 112 200 $c $false
    $rf.Add_Click({ Busy $true (L 'working'); & $refresh; Busy $false '' }.GetNewClosure())

    Gap 4
    P (L 'f.pick')
    SetNav (L 'next') $true $true
}

# ---------------------------------------------------------------- storage ---
function Page_gates() {
    DrawSide 6
    H1 (L 'g.t')
    P (L 'g.b')
    $c = Card 210
    Busy $true (L 'working')
    $script:Gates = Test-Gates
    Busy $false ''

    $g = $script:Gates
    $names = @('g.1', 'g.2', 'g.3', 'g.4', 'g.5')
    $keys  = @('unlocked', 'ab', 'spare', 'maps', 'fresh')
    for ($i = 0; $i -lt 5; $i++) {
        $pass = [bool]$g[$keys[$i]]
        Row $c (16 + $i * 32) (L $names[$i]) $(if ($pass) { (L 'g.pass') } else { (L 'g.fail') }) $(if ($pass) { 'ok' } else { 'err' })
    }
    $all = $g['unlocked'] -and $g['ab'] -and $g['spare'] -and $g['maps'] -and $g['fresh']
    $n = New-Object Windows.Forms.Label
    $n.Location = (PT 16 180)
    $n.Size = (SZ 636 24); $n.Font = (F 10 $true)
    $n.Text = $(if ($all) { (L 'g.go') } else { (L 'g.stop') })
    $n.ForeColor = $(if ($all) { $C_OK } else { $C_ERR })
    $c.Controls.Add($n)

    Gap 4
    Bullet (L 'g.1x') $C_MUTE
    Bullet (L 'g.3x') $C_MUTE
    Bullet (L 'g.4x') $C_MUTE
    if ($g['detail']) { P $g['detail'] }
    SetNav (L 'next') $all $true
}

function Page_cost() {
    DrawSide 6
    H1 (L 'k.t')
    Gap 2
    Bullet (L 'k.1') $C_WARN
    Bullet (L 'k.2') $C_WARN
    Bullet (L 'k.3') $C_WARN
    Bullet (L 'k.4') $C_MUTE
    Bullet (L 'k.5') $C_MUTE
    Gap 10
    $c = Card 96
    $ck = New-Object Windows.Forms.CheckBox
    $ck.Text = (L 'k.ack'); $ck.Location = (PT 16 14)
    $ck.Size = (SZ 636 24); $ck.ForeColor = $C_TEXT
    $c.Controls.Add($ck)
    $lb = New-Object Windows.Forms.Label
    $lb.Text = (L 'k.type'); $lb.Location = (PT 16 50)
    $lb.Size = (SZ 240 24); $lb.ForeColor = $C_MUTE
    $c.Controls.Add($lb)
    $tb = New-Object Windows.Forms.TextBox
    $tb.Location = (PT 262 48); $tb.Size = (SZ 200 26)
    $tb.BackColor = $C_BG; $tb.ForeColor = $C_TEXT; $tb.BorderStyle = 'FixedSingle'
    $tb.RightToLeft = 'No'
    $c.Controls.Add($tb)

    $upd = { $BtnNext.Enabled = ($ck.Checked -and $tb.Text.Trim().ToUpper() -eq 'UPGRADE') }
    $ck.Add_CheckedChanged($upd)
    $tb.Add_TextChanged($upd)
    SetNav (L 'next') $false $true
}

function Page_backup() {
    DrawSide 6
    H1 (L 'b.t')
    P (L 'b.b')
    $c = Card 150
    $pl = New-Object Windows.Forms.Label
    $pl.Text = (L 'b.where') + ':  ' + $script:BackupTo
    $pl.Location = (PT 16 16); $pl.Size = (SZ 636 24)
    $pl.ForeColor = $C_MUTE
    $c.Controls.Add($pl)
    $ch = Btn (L 'b.choose') 16 48 220 $c $false
    $ch.Add_Click({
        $d = New-Object Windows.Forms.FolderBrowserDialog
        if ($d.ShowDialog() -eq 'OK') { $script:BackupTo = $d.SelectedPath; $pl.Text = (L 'b.where') + ':  ' + $script:BackupTo }
    }.GetNewClosure())
    $st = New-Object Windows.Forms.Label
    $st.Location = (PT 16 110); $st.Size = (SZ 636 30)
    $st.ForeColor = $C_MUTE
    $c.Controls.Add($st)
    $go = Btn (L 'b.run') 252 48 200 $c $true
    $go.Add_Click({
        Busy $true (L 'working')
        $r = Save-Backup
        $st.Text = $r; $st.ForeColor = $C_OK
        $BtnNext.Enabled = $true
        Busy $false ''
    }.GetNewClosure())
    SetNav (L 'next') $false $true
}

function Page_edit() {
    DrawSide 6
    H1 (L 'e.t')
    P (L 'e.b')
    $c = Card 210
    $out = New-Object Windows.Forms.RichTextBox
    $out.Location = (PT 16 54); $out.Size = (SZ 636 140)
    $out.BackColor = $C_BG; $out.ForeColor = $C_MUTE; $out.ReadOnly = $true
    $out.Font = New-Object Drawing.Font('Consolas', 8)
    $out.BorderStyle = 'None'; $out.RightToLeft = 'No'
    $c.Controls.Add($out)
    $go = Btn (L 'e.run') 16 12 220 $c $true
    $st = New-Object Windows.Forms.Label
    $st.Location = (PT 252 18); $st.Size = (SZ 400 30)
    $st.Font = (F 10 $true)
    $c.Controls.Add($st)
    $go.Add_Click({
        Busy $true (L 'working')
        $r = Apply-Fstab
        $out.Text = $r.Text
        Busy $false ''
        # After Busy, never before - Busy re-enables Next unconditionally.
        if ($r.Ok) { $st.Text = (L 'e.ok'); $st.ForeColor = $C_OK; $BtnNext.Enabled = $true }
        else       { $st.Text = (L 'e.err'); $st.ForeColor = $C_ERR; $BtnNext.Enabled = $false }
    }.GetNewClosure())
    SetNav (L 'next') $false $true
}

function Page_recovery() {
    DrawSide 6
    H1 (L 'r.t')
    P (L 'r.b')
    $c = Card 300

    $step = {
        param($n, $title, $body, $cn, $y)
        $a = New-Object Windows.Forms.Label
        $a.Text = "$n.  $title"; $a.Location = (PT 16 $y)
        $a.Size = (SZ 636 24); $a.Font = (F 11 $true); $a.ForeColor = $C_TEXT
        $c.Controls.Add($a)
        $b = New-Object Windows.Forms.Label
        $b.Text = $body; $b.Location = New-Object Drawing.Point(38, ($y + 26))
        $b.Size = (SZ 420 36); $b.ForeColor = $C_MUTE
        $c.Controls.Add($b)
        if ($cn) {
            $d = New-Object Windows.Forms.Label
            $d.Text = $cn; $d.Location = New-Object Drawing.Point(470, ($y + 22))
            $d.Size = (SZ 190 34); $d.Font = (F 14 $true); $d.ForeColor = $C_GOLD
            $d.RightToLeft = 'No'
            $c.Controls.Add($d)
        }
    }

    & $step 1 (L 'r.boot') (L 'r.bootb') '' 12
    & $step 2 (L 'r.i8')   (L 'r.i8b')   '8  格式化地图分区' 84
    & $step 3 (L 'r.i11')  (L 'r.i11b')  '11 切换到备份系统' 156

    $rb = Btn (L 'r.boot') 16 236 300 $c $true
    $rb.Add_Click({ Adb @('reboot', 'recovery') | Out-Null })

    $ck = New-Object Windows.Forms.CheckBox
    $ck.Text = (L 'r.did'); $ck.Location = (PT 336 242)
    $ck.Size = (SZ 320 24); $ck.ForeColor = $C_TEXT
    $c.Controls.Add($ck)
    $ck.Add_CheckedChanged({ $BtnNext.Enabled = $ck.Checked }.GetNewClosure())
    SetNav (L 'next') $false $true
}

function Page_wait() {
    DrawSide 6
    H1 (L 'x.t')
    Gap 2
    Bullet (L 'x.1')
    Bullet (L 'x.2')
    P '设置 → 关于本机 → 版本号 (x7) → 开发者选项 → USB调试'
    Gap 6
    $c = Card 120
    $st = New-Object Windows.Forms.Label
    $st.Location = (PT 16 16); $st.Size = (SZ 636 46)
    $st.Font = (F 11 $true); $st.Text = (L 'x.wait'); $st.ForeColor = $C_MUTE
    $c.Controls.Add($st)
    $dt = New-Object Windows.Forms.Label
    $dt.Location = (PT 16 68); $dt.Size = (SZ 636 40)
    $dt.ForeColor = $C_MUTE
    $c.Controls.Add($dt)

    SetNav (L 'next') $false $true
    $script:Timer = New-Object Windows.Forms.Timer
    $script:Timer.Interval = 3000
    $script:Timer.Add_Tick({
        if ($script:Busy) { return }
        $out = Adb @('devices') -NoDevice -Quiet
        $ok = @(($out -split "`r?`n") | Where-Object { $_ -match '^\s*(\S+)\s+device\s*$' })
        if ($ok.Count -ne 1) { return }
        $script:Timer.Stop()
        $script:Serial = ($ok[0] -split '\s+')[0]
        Adb @('root') | Out-Null; Adb @('wait-for-device') | Out-Null
        $script:Info = Read-Unit
        $sw = ($script:Info['data_dev'] -eq $script:Info['byname_inand'])
        if ($sw) { $st.Text = (L 'x.ok'); $st.ForeColor = $C_OK } else { $st.Text = (L 'x.bad'); $st.ForeColor = $C_ERR }
        $dt.Text = ('/data = ' + $script:Info['data_dev'] + '   ' + (HumanKB $script:Info['data_free']) + ' free of ' + (HumanKB $script:Info['data_total']))
        $BtnNext.Enabled = $true
    })
    $script:Timer.Start()
    $script:OnNext = { if ($script:Timer) { $script:Timer.Stop() }; Go 1 }
}

# ---------------------------------------------------------------- install ---
function Page_install() {
    DrawSide 7
    H1 (L 'i.t')
    P (L 'i.b')
    $c = Card 330
    $names = @('i.s1', 'i.s2', 'i.s3', 'i.s4', 'i.s5', 'i.s6', 'i.s7', 'i.s8', 'i.s9')
    $labels = @()
    for ($i = 0; $i -lt $names.Count; $i++) {
        $l = New-Object Windows.Forms.Label
        $l.Text = ([char]0x25CB) + '   ' + (L $names[$i])
        $l.Location = New-Object Drawing.Point(16, (56 + $i * 28))
        $l.Size = (SZ 636 24); $l.ForeColor = $C_MUTE
        $c.Controls.Add($l)
        $labels += $l
    }
    $script:StepLabels = $labels

    $go = Btn (L 'i.run') 16 12 220 $c $true
    $go.Add_Click({
        $go.Enabled = $false
        Busy $true (L 'working')
        Run-Install
        Busy $false ''
        $BtnNext.Enabled = $true
    }.GetNewClosure())
    SetNav (L 'next') $false $true
}

function MarkStep($i, $state) {
    if (-not $script:StepLabels) { return }
    $l = $script:StepLabels[$i]
    $mark = switch ($state) { 'run' { [char]0x25B6 } 'ok' { [char]0x2713 } 'err' { [char]0x2717 } default { [char]0x25CB } }
    $l.Text = "$mark   " + ($l.Text -replace '^.\s+', '')
    $l.ForeColor = switch ($state) { 'ok' { $C_OK } 'err' { $C_ERR } 'run' { $C_GOLD } default { $C_MUTE } }
    [Windows.Forms.Application]::DoEvents()
}

function Page_done() {
    DrawSide 8
    H1 (L 'v.t')
    $c = Card 280
    $v = $script:Verify
    if (-not $v) { $v = @{} }
    $rows = @(
        @((L 'v.app'),    $v['app'],    $v['app_s']),
        @((L 'v.bar'),    $v['bar'],    $v['bar_s']),
        @((L 'v.launch'), $v['launch'], $v['launch_s']),
        @((L 'v.login'),  $v['login'],  $v['login_s']),
        @((L 'v.home'),   $v['home'],   $v['home_s']),
        @((L 'v.free'),   $v['free'],   $v['free_s']),
        @((L 'v.voice'),  $v['voice'],  $v['voice_s']),
        @((L 'v.data'),   $v['data'],   'plain')
    )
    for ($i = 0; $i -lt $rows.Count; $i++) {
        Row $c (16 + $i * 30) $rows[$i][0] "$($rows[$i][1])" "$($rows[$i][2])"
    }
    if ($script:Plan -eq 'storage') {
        $sl = New-Object Windows.Forms.Label
        $sl.Location = (PT 16 236); $sl.Size = (SZ 636 22)
        $sl.Font = (F 8)
        $sl.ForeColor = $C_MUTE
        $sl.Text = (L 'd.slot')
        $c.Controls.Add($sl)
    }
    $n = New-Object Windows.Forms.Label
    $n.Location = (PT 16 258); $n.Size = (SZ 636 24)
    $n.Font = (F 10 $true)
    $bad = $v['fail']
    $n.Text = $(if ($bad) { (L 'v.some') } else { (L 'v.allok') })
    $n.ForeColor = $(if ($bad) { $C_WARN } else { $C_OK })
    $c.Controls.Add($n)

    $c2 = Card 60
    $sl = Btn (L 'v.log') 16 12 220 $c2 $false
    $sl.Add_Click({
        $d = New-Object Windows.Forms.SaveFileDialog
        $d.FileName = 'luxdash-report.txt'; $d.Filter = 'Text|*.txt'
        if ($d.ShowDialog() -eq 'OK') { Copy-Item $script:LogFile $d.FileName -Force }
    })
    $rs = Btn (L 'v.restore') 252 12 300 $c2 $false
    $rs.Add_Click({ Busy $true (L 'working'); Restore-Backup; Busy $false '' })
    SetNav (L 'finish') $true $true
}

function Page_undo() {
    DrawSide 8
    H1 (L 'u.t')
    Gap 4
    $c = Card 130
    $st = New-Object Windows.Forms.Label
    $st.Location = (PT 16 62); $st.Size = (SZ 636 50)
    $st.ForeColor = $C_MUTE
    $c.Controls.Add($st)
    $go = Btn (L 'u.run') 16 14 220 $c $true
    $go.Add_Click({
        Busy $true (L 'working')
        Run-Undo
        $st.Text = (L 'u.ok'); $st.ForeColor = $C_OK
        Busy $false ''
    }.GetNewClosure())
    $rb = Btn (L 'u.reboot') 252 14 220 $c $false
    $rb.Add_Click({ Adb @('reboot') | Out-Null })
    SetNav (L 'finish') $true $true
}

# =============================================================================
# WORK
# =============================================================================

function Find-Adb() {
    $here = Split-Path -Parent $env:LUXSELF
    foreach ($p in @(
        (Join-Path $script:Root 'platform-tools\adb.exe'),
        (Join-Path $here 'platform-tools\adb.exe'),
        (Join-Path $here 'adb.exe')
    )) { if (Test-Path $p) { return $p } }
    $w = Get-Command adb -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    return $null
}

function Find-Apk() {
    $here = Split-Path -Parent $env:LUXSELF
    foreach ($p in @(
        (Join-Path $script:Root 'cardashboard-car-release.apk'),
        (Join-Path $here 'cardashboard-car-release.apk'),
        (Join-Path $here 'CarDashboard.apk')
    )) { if (Test-Path $p) { return $p } }
    return $null
}

function Find-Model() {
    $here = Split-Path -Parent $env:LUXSELF
    foreach ($p in @(
        (Join-Path $script:Root 'ggml-base.bin'),
        (Join-Path $here 'ggml-base.bin'),
        (Join-Path $here 'voice-model\whisper\ggml-base.bin'),
        (Join-Path (Split-Path -Parent $here) 'voice-model\whisper\ggml-base.bin')
    )) { if (Test-Path $p) { return $p } }
    return $null
}

function Get-PlatformTools() {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $script:Root 'platform-tools.zip'
    Log "downloading $PT_URL"
    Invoke-WebRequest -UseBasicParsing -Uri $PT_URL -OutFile $zip
    if (Test-Path (Join-Path $script:Root 'platform-tools')) {
        Remove-Item (Join-Path $script:Root 'platform-tools') -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $script:Root)
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

function Get-Apk() {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $dst = Join-Path $script:Root 'cardashboard-car-release.apk'
    Log "downloading $APK_URL"
    Invoke-WebRequest -UseBasicParsing -Uri $APK_URL -OutFile $dst
}

function Read-Unit() {
    $s = @'
setenforce 0 2>/dev/null
echo "model=$(getprop ro.product.model)"
echo "device=$(getprop ro.product.device)"
echo "android=$(getprop ro.build.version.release)"
echo "slot=$(getprop ro.boot.slot_suffix)"
echo "vbs=$(getprop ro.boot.verifiedbootstate)"
echo "ab=$(getprop ro.build.ab_update)"
echo "gate=$(getprop com.qinggan.user_started)"
d=$(df /data 2>/dev/null | tail -1)
echo "data_total=$(echo $d | awk '{print $2}')"
echo "data_free=$(echo $d | awk '{print $4}')"
echo "data_dev=$(grep ' /data ' /proc/mounts | head -1 | awk '{print $1}')"
i=$(df /inand 2>/dev/null | tail -1)
echo "inand_free=$(echo $i | awk '{print $4}')"
echo "byname_inand=$(readlink -f /dev/block/by-name/inand 2>/dev/null)"
echo "byname_userdata=$(readlink -f /dev/block/by-name/userdata 2>/dev/null)"
echo "dash=$(dumpsys package com.cardash.dashboard 2>/dev/null | grep -m1 versionName | cut -d= -f2)"
echo "wifi=$(settings get global wifi_on)"
setenforce 1 2>/dev/null
'@
    return (ParseKV (ShFile $s))
}

function Test-Gates() {
    $s = @'
setenforce 0 2>/dev/null
cur=$(getprop ro.boot.slot_suffix)
if [ "$cur" = "_a" ]; then other=_b; else other=_a; fi
echo "other=$other"
echo "vbs=$(getprop ro.boot.verifiedbootstate)"
echo "ab=$(getprop ro.build.ab_update)"
n=0
for p in system_a system_b vendor_a vendor_b; do
  [ -e /dev/block/by-name/$p ] && n=$((n+1))
done
echo "parts=$n"
echo "fp_run=$(getprop ro.build.fingerprint)"
mkdir -p /mnt/luxchk
umount /mnt/luxchk 2>/dev/null
if mount -o ro /dev/block/by-name/system$other /mnt/luxchk 2>/dev/null; then
  # The partition may be system-as-root (build.prop at the top) or hold a
  # system/ directory. Try both rather than assume a layout.
  fpo=$(grep -m1 '^ro.build.fingerprint=' /mnt/luxchk/build.prop 2>/dev/null | cut -d= -f2-)
  [ -z "$fpo" ] && fpo=$(grep -m1 '^ro.build.fingerprint=' /mnt/luxchk/system/build.prop 2>/dev/null | cut -d= -f2-)
  echo "fp_other=$fpo"
  umount /mnt/luxchk 2>/dev/null
else
  echo "fp_other="
fi
rmdir /mnt/luxchk 2>/dev/null
echo "maps_mb=$(du -sm /inand/BaiduMapAuto 2>/dev/null | awk '{print $1}')"
echo "inand_mb=$(du -sm /inand 2>/dev/null | awk '{print $1}')"
echo "data_dev=$(grep ' /data ' /proc/mounts | head -1 | awk '{print $1}')"
echo "byname_inand=$(readlink -f /dev/block/by-name/inand 2>/dev/null)"
setenforce 1 2>/dev/null
'@
    $k = ParseKV (ShFile $s)
    $mapsMb = 0; [void][int]::TryParse("$($k['maps_mb'])", [ref]$mapsMb)
    $g = @{}
    $g['unlocked'] = ($k['vbs'] -eq 'orange')
    $g['ab']       = (($k['ab'] -eq 'true') -and ("$($k['parts'])" -eq '4'))
    # The spare system counts as usable only when its build string is present AND
    # identical to the running one. A different or missing fingerprint means we
    # cannot promise it boots, so the gate fails rather than guesses.
    $g['spare']    = ($k['fp_other'] -and $k['fp_run'] -and ($k['fp_other'] -eq $k['fp_run']))
    $g['maps']     = ($mapsMb -lt 200)
    $g['fresh']    = ($k['data_dev'] -ne $k['byname_inand'])
    $g['other']    = $k['other']
    $g['detail']   = "slot $($k['other']) | maps ${mapsMb} MB | /inand $($k['inand_mb']) MB"
    $g['raw']      = $k
    return $g
}

function Save-Backup() {
    $stamp = Get-Date -Format 'yyyy-MM-dd'
    $dir = Join-Path $script:BackupTo "luxdash-backup-$stamp"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # App list first - it is what tells the owner what to reinstall afterwards.
    $pkgs = Sh 'pm list packages -3'
    [IO.File]::WriteAllText((Join-Path $dir 'installed-apps.txt'), $pkgs, (New-Object Text.UTF8Encoding($false)))

    if ($script:Info['dash']) {
        $s = @'
setenforce 0 2>/dev/null
rm -f /data/local/tmp/cardash-data.tgz
tar czf /data/local/tmp/cardash-data.tgz -C /data/data com.cardash.dashboard 2>/dev/null
setenforce 1 2>/dev/null
ls -l /data/local/tmp/cardash-data.tgz
'@
        ShFile $s | Out-Null
        Adb @('pull', '/data/local/tmp/cardash-data.tgz', (Join-Path $dir 'cardash-data.tgz')) | Out-Null
        Sh 'rm -f /data/local/tmp/cardash-data.tgz' | Out-Null
    }
    $script:BackupDir = $dir
    return (L 'b.done') + "  $dir"
}

function Restore-Backup() {
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = 'Backup (cardash-data.tgz)|cardash-data.tgz|All|*.*'
    if ($d.ShowDialog() -ne 'OK') { return }
    Adb @('push', $d.FileName, '/data/local/tmp/cardash-data.tgz') | Out-Null
    $s = @'
setenforce 0 2>/dev/null
tar xzf /data/local/tmp/cardash-data.tgz -C /data/data
setenforce 1 2>/dev/null
am force-stop com.cardash.dashboard
rm -f /data/local/tmp/cardash-data.tgz
echo restored
'@
    ShFile $s | Out-Null
}

# Swap the /data and /inand lines in the INACTIVE slot's fstab.
# Never touches the running slot, so a mistake here cannot strand the unit.
function Apply-Fstab() {
    $s = @'
setenforce 0 2>/dev/null
cur=$(getprop ro.boot.slot_suffix)
if [ "$cur" = "_a" ]; then other=_b; else other=_a; fi
mkdir -p /mnt/luxv
umount /mnt/luxv 2>/dev/null
if ! mount -o rw /dev/block/by-name/vendor$other /mnt/luxv 2>/dev/null; then echo "err=mount"; exit 1; fi
f=/mnt/luxv/etc/fstab.freescale
if [ ! -f "$f" ]; then echo "err=nofstab"; umount /mnt/luxv; exit 1; fi
cp "$f" /data/local/tmp/fstab.backup
echo "--- BEFORE ---"
grep -E '^/dev/block/by-name/(userdata|inand)[[:space:]]' "$f"
awk '
$1=="/dev/block/by-name/userdata" && $2=="/data" {
    $1="/dev/block/by-name/inand"; sub(/,errors=panic/,"",$4); sub(/errors=panic,/,"",$4); print; next }
$1=="/dev/block/by-name/inand" && $2=="/inand" {
    $1="/dev/block/by-name/userdata"; sub(/,resize/,"",$5); sub(/resize,/,"",$5); print; next }
{ print }
' "$f" > /data/local/tmp/fstab.new
n1=$(awk '$1=="/dev/block/by-name/inand" && $2=="/data"' /data/local/tmp/fstab.new | wc -l)
n2=$(awk '$1=="/dev/block/by-name/userdata" && $2=="/inand"' /data/local/tmp/fstab.new | wc -l)
if [ "$n1" != "1" ] || [ "$n2" != "1" ]; then
  echo "err=transform n1=$n1 n2=$n2"; umount /mnt/luxv; rmdir /mnt/luxv; exit 1
fi
cr=$(tr -cd '\r' < /data/local/tmp/fstab.new | wc -c)
if [ "$cr" != "0" ]; then echo "err=crlf"; umount /mnt/luxv; rmdir /mnt/luxv; exit 1; fi
cat /data/local/tmp/fstab.new > "$f"
sync
echo "--- AFTER ---"
grep -E '^/dev/block/by-name/(userdata|inand)[[:space:]]' "$f"
umount /mnt/luxv 2>/dev/null
rmdir /mnt/luxv 2>/dev/null
setenforce 1 2>/dev/null
echo "ok=1"
'@
    $r = ShFile $s
    $ok = ($r -match '(?m)^ok=1\s*$')
    if ($ok -and $script:BackupDir) {
        Adb @('pull', '/data/local/tmp/fstab.backup', (Join-Path $script:BackupDir 'fstab.freescale.original')) | Out-Null
    }
    return @{ Ok = $ok; Text = $r }
}

function Run-Install() {
    $v = @{}

    # 1 - the app
    MarkStep 0 'run'
    $r = Adb @('install', '-r', '-g', $script:Apk)
    if ($r -notmatch 'Success') {
        Log 'reinstall refused - clean install' '!'
        Adb @('uninstall', $PKG) | Out-Null
        $r = Adb @('install', '-g', $script:Apk)
    }
    MarkStep 0 $(if ($r -match 'Success') { 'ok' } else { 'err' })

    # 2 - voice model onto whichever partition has room
    # /inand is the 16 GB bulk partition on a STOCK unit. On an UPGRADED unit it
    # is the small one AND it holds the other system's data, so 142 MB dumped
    # there eats the system you would switch back to. Ask which has room.
    MarkStep 1 'run'
    $destScript = @'
I=$(df /inand 2>/dev/null | tail -1 | awk '{print $4}')
D=$(df /data | tail -1 | awk '{print $4}')
if [ ${I:-0} -gt ${D:-0} ]; then
  echo dest=/inand/cardash/whisper
else
  echo dest=/data/media/0/Android/data/com.cardash.dashboard/files/whisper
fi
'@
    $dest = (ParseKV (ShFile $destScript))['dest']
    if (-not $dest) { $dest = "$INAND/whisper" }
    $script:ModelDir = $dest
    if ($script:Model) {
        $have = (Sh "ls $dest/ggml-base.bin 2>/dev/null").Trim()
        if ($have) {
            MarkStep 1 'ok'
        } else {
            Sh "setenforce 0; mkdir -p $dest" | Out-Null
            Adb @('push', $script:Model, "$dest/ggml-base.bin") | Out-Null
            Sh "chown -R media_rw:media_rw $dest; chmod -R 755 $dest; setenforce 1" | Out-Null
            MarkStep 1 'ok'
        }
    } else {
        MarkStep 1 'ok'   # the app downloads it itself; not a failure
    }
    Sh "mkdir -p $INAND/osm $INAND/whisper; chmod 777 $INAND/osm $INAND/whisper" | Out-Null

    # 3 - vendor status bar
    MarkStep 2 'run'
    Sh 'pm disable-user --user 0 com.qinggan.systemui' | Out-Null
    MarkStep 2 'ok'

    # 4 - boot voice, music toasts, extra launchers, and AutoKit's auto-start.
    #     The FM radio is deliberately NOT disabled: disabling it hides it from every app picker,
    #     so it cannot be bound to a dock slot or opened in a cockpit tile. The dashboard hands the
    #     audio source over through the vendor API instead of killing the radio (0.7).
    MarkStep 3 'run'
    Sh 'pm disable-user --user 0 com.qinggan.now.ui'    | Out-Null
    Sh 'pm disable-user --user 0 com.qinggan.app.music' | Out-Null
    Sh 'pm disable-user --user 0 com.android.launcher3' | Out-Null
    Sh 'pm disable com.qinggan.app.launcher/com.qinggan.app.launcher.activity.MainActivity' | Out-Null
    # AutoKit (Carlinkit) starts itself over the dashboard at every boot. Disable only the
    # auto-start receiver, so the app still opens normally when the driver taps it.
    Sh 'pm disable cn.manstep.phonemirrorBox/cn.manstep.phonemirrorBox.AutoStartReceiver' | Out-Null
    MarkStep 3 'ok'

    # 5 - the build.prop gate that makes boot fast. It is also the safety
    #     interlock for disabling the login chooser later: login's MyApp only
    #     force-launches RootActivity when this property is EMPTY.
    MarkStep 4 'run'
    $gate = @'
setenforce 0
d=$(readlink -f /dev/block/by-name/system$(getprop ro.boot.slot_suffix) 2>/dev/null)
[ -z "$d" ] && d=$(readlink -f /dev/block/by-name/system)
blockdev --setrw $d
mount -o rw,remount /
grep -q 'com.qinggan.user_started' /system/build.prop || printf '\n# LuxDash: skip the vendor login chooser at boot\ncom.qinggan.user_started=1\n' >> /system/build.prop
sync
getprop com.qinggan.user_started
grep -c 'com.qinggan.user_started' /system/build.prop
'@
    $gr = ShFile $gate
    MarkStep 4 $(if ($gr -match '(?m)^\s*[1-9]') { 'ok' } else { 'err' })

    # 6 - home screen + freeform + notification access
    MarkStep 5 'run'
    Sh 'settings put global enable_freeform_support 1'     | Out-Null
    Sh 'settings put global force_resizable_activities 1'  | Out-Null
    Sh "cmd notification allow_listener $LISTENER"         | Out-Null
    $sh = Sh "cmd package set-home-activity $HOME_ACT"
    MarkStep 5 $(if ($sh -match 'Exception|Error|Failure') { 'err' } else { 'ok' })

    # 7 - reboot (persistent apps only honour the disable on a fresh boot)
    MarkStep 6 'run'
    Adb @('reboot') | Out-Null
    Adb @('wait-for-device') | Out-Null
    $tries = 0
    while ($tries -lt 90) {
        Start-Sleep -Seconds 4
        [Windows.Forms.Application]::DoEvents()
        $b = (Sh 'getprop sys.boot_completed').Trim()
        if ($b -match '1') { break }
        $tries++
    }
    Adb @('root') | Out-Null; Adb @('wait-for-device') | Out-Null
    Start-Sleep -Seconds 3
    MarkStep 6 'ok'

    # 8 - second pass. On a unit whose /data was wiped, the vendor's first-run
    #     provisioning re-enables everything disabled before the reboot.
    MarkStep 7 'run'
    Sh 'pm disable-user --user 0 com.qinggan.systemui'   | Out-Null
    Sh 'pm disable-user --user 0 com.qinggan.now.ui'     | Out-Null
    Sh 'pm disable-user --user 0 com.qinggan.app.music'  | Out-Null
    Sh 'pm disable-user --user 0 com.android.launcher3'  | Out-Null
    Sh 'pm disable com.qinggan.app.launcher/com.qinggan.app.launcher.activity.MainActivity' | Out-Null
    Sh 'pm disable cn.manstep.phonemirrorBox/cn.manstep.phonemirrorBox.AutoStartReceiver' | Out-Null
    Sh "cmd package set-home-activity $HOME_ACT"         | Out-Null
    Sh 'settings put global enable_freeform_support 1'   | Out-Null
    Sh 'settings put global force_resizable_activities 1'| Out-Null
    Sh "cmd notification allow_listener $LISTENER"       | Out-Null
    # Only kill the login chooser when the gate is really in place - without it
    # the persistent login process crash-loops and takes the knob and Wi-Fi with it.
    $g = (Sh 'getprop com.qinggan.user_started').Trim()
    if ($g) { Sh 'pm disable com.qinggan.app.login/com.qinggan.app.login.RootActivity' | Out-Null }
    else    { Log 'gate empty - NOT disabling RootActivity' '!' }
    MarkStep 7 'ok'

    Sh "am start -n $ACT" | Out-Null

    # 9 - verify. Nothing above is claimed to have worked until it is read back.
    MarkStep 8 'run'
    $ver = @"
echo "ver=`$(dumpsys package $PKG | grep -m1 versionName | cut -d= -f2)"
echo "disabled=`$(pm list packages -d)"
echo "home=`$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -1)"
echo "free=`$(settings get global enable_freeform_support)"
echo "model=`$(ls $($script:ModelDir)/ggml-base.bin 2>/dev/null)"
d=`$(df /data | tail -1)
echo "dt=`$(echo `$d | awk '{print `$2}')"
echo "df=`$(echo `$d | awk '{print `$4}')"
"@
    $k = ParseKV (ShFile $ver)
    $dis = "$($k['disabled'])"
    $v['app']    = $(if ($k['ver']) { $k['ver'] } else { '-' })
    $v['app_s']  = $(if ($k['ver']) { 'ok' } else { 'err' })
    $v['bar']    = $(if ($dis -match 'com\.qinggan\.systemui') { (L 'd.yes') } else { (L 'd.no') })
    $v['bar_s']  = $(if ($dis -match 'com\.qinggan\.systemui') { 'ok' } else { 'err' })
    $v['launch'] = $(if ($dis -match 'com\.android\.launcher3') { (L 'd.yes') } else { (L 'd.no') })
    $v['launch_s'] = $(if ($dis -match 'com\.android\.launcher3') { 'ok' } else { 'err' })
    $v['login']  = $(if ("$($k['home'])" -match 'qinggan\.app\.login') { (L 'd.no') } else { (L 'd.yes') })
    $v['login_s']= $(if ("$($k['home'])" -match 'qinggan\.app\.login') { 'err' } else { 'ok' })
    $v['home']   = $(if ("$($k['home'])" -match 'cardash') { (L 'd.yes') } else { (L 'd.no') })
    $v['home_s'] = $(if ("$($k['home'])" -match 'cardash') { 'ok' } else { 'err' })
    $v['free']   = $(if ("$($k['free'])" -match '1') { (L 'd.yes') } else { (L 'd.no') })
    $v['free_s'] = $(if ("$($k['free'])" -match '1') { 'ok' } else { 'err' })
    $v['voice']  = $(if ($k['model']) { (L 'd.yes') } else { (L 't.skip') })
    $v['voice_s']= $(if ($k['model']) { 'ok' } else { 'warn' })
    $v['data']   = (HumanKB $k['df']) + ' / ' + (HumanKB $k['dt'])
    $v['fail']   = @('app_s','bar_s','launch_s','login_s','home_s','free_s') | Where-Object { $v[$_] -eq 'err' } | Select-Object -First 1
    $script:Verify = $v
    MarkStep 8 $(if ($v['fail']) { 'err' } else { 'ok' })
}

function Run-Undo() {
    foreach ($p in @('com.qinggan.systemui', 'com.qinggan.now.ui', 'com.qinggan.app.music',
                     'com.qinggan.app.radio', 'com.android.launcher3')) {
        Sh "pm enable $p" | Out-Null
    }
    Sh 'pm enable com.qinggan.app.launcher/com.qinggan.app.launcher.activity.MainActivity' | Out-Null
    Sh 'pm enable cn.manstep.phonemirrorBox/cn.manstep.phonemirrorBox.AutoStartReceiver' | Out-Null
    Sh 'pm enable com.qinggan.app.login/com.qinggan.app.login.RootActivity' | Out-Null
}

# =============================================================================
Log "LuxDash Setup starting - $env:LUXSELF  (dpi scale $script:S)"
Render
[void]$Form.ShowDialog()
if ($script:Timer) { $script:Timer.Stop() }
