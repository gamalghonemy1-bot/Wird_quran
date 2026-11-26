import re, os
m = 'android/app/src/main/AndroidManifest.xml'
s = open(m, encoding='utf-8').read()
perms = '''<uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
    '''
s = s.replace('<application', perms + '<application', 1)
recv = '''<receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>
    '''
s = s.replace('</application>', recv + '</application>', 1)
s = s.replace('android:label="wird_daily"', 'android:label="الورد اليومي"')
open(m, 'w', encoding='utf-8').write(s)

for f in ['android/app/build.gradle.kts', 'android/app/build.gradle']:
    if not os.path.exists(f):
        continue
    t = open(f, encoding='utf-8').read()
    if f.endswith('.kts'):
        t = re.sub(r'compileOptions\s*\{', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', t, 1)
        t += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
        # إيقاف R8: يكسر مكتبة الإشعارات المجدولة (Missing type parameter)
        t = re.sub(r'(buildTypes\s*\{\s*release\s*\{)', r'\1\n            isMinifyEnabled = false\n            isShrinkResources = false', t, 1)
    else:
        t = re.sub(r'compileOptions\s*\{', 'compileOptions {\n        coreLibraryDesugaringEnabled true', t, 1)
        t += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
        t = re.sub(r'(buildTypes\s*\{\s*release\s*\{)', r'\1\n            minifyEnabled false\n            shrinkResources false', t, 1)
    open(f, 'w', encoding='utf-8').write(t)

# السماح بظهور التطبيق فوق شاشة القفل عند التنبيه
s = open(m, encoding='utf-8').read()
s = s.replace('<activity', '<activity android:showWhenLocked="true" android:turnScreenOn="true"', 1)
open(m, 'w', encoding='utf-8').write(s)

# صوت التنبيه: إن وُجد ملف صوتي مسجّل في مجلد sound يُستعمل، وإلا تُولَّد نغمة جرس
import shutil, wave, struct, math
raw = 'android/app/src/main/res/raw'
os.makedirs(raw, exist_ok=True)
custom = None
for ext in ['mp3', 'ogg', 'wav', 'm4a']:
    cand = f'sound/wird_alert.{ext}'
    if os.path.exists(cand):
        custom = (cand, ext)
        break
if custom:
    shutil.copy(custom[0], f'{raw}/wird_alert.{custom[1]}')
    print('using custom sound', custom[0])
else:
    sr = 22050
    dur = 3.0
    buf = [0.0] * int(sr * dur)
    for start, f in [(0.0, 523.25), (0.45, 659.25), (0.9, 783.99), (1.5, 1046.5)]:
        for i in range(int(sr * (dur - start))):
            t = i / sr
            env = math.exp(-2.6 * t) * (1 - math.exp(-t * 150))
            v = math.sin(2*math.pi*f*t) + 0.5*math.sin(2*math.pi*2*f*t) + 0.25*math.sin(2*math.pi*3*f*t)
            buf[int(start*sr) + i] += v * env
    mx = max(abs(x) for x in buf) or 1
    with wave.open(f'{raw}/wird_alert.wav', 'w') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes(b''.join(struct.pack('<h', int(x / mx * 30000)) for x in buf))
