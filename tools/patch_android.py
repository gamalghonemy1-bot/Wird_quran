import re, os
m = 'android/app/src/main/AndroidManifest.xml'
s = open(m, encoding='utf-8').read()
perms = '''<uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
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
s = s.replace('<activity', '<activity android:showWhenLocked="true" android:turnScreenOn="true"', 1)
s = s.replace('android:label="wird_daily"', 'android:label="الورد اليومي"')
open(m, 'w', encoding='utf-8').write(s)

for f in ['android/app/build.gradle.kts', 'android/app/build.gradle']:
    if not os.path.exists(f):
        continue
    t = open(f, encoding='utf-8').read()
    if f.endswith('.kts'):
        t = re.sub(r'(buildTypes\s*\{\s*release\s*\{)', r'\1\n            isMinifyEnabled = false\n            isShrinkResources = false', t, 1)
        t = re.sub(r'compileOptions\s*\{', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', t, 1)
        t += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
    else:
        t = re.sub(r'(buildTypes\s*\{\s*release\s*\{)', r'\1\n            minifyEnabled false\n            shrinkResources false', t, 1)
        t = re.sub(r'compileOptions\s*\{', 'compileOptions {\n        coreLibraryDesugaringEnabled true', t, 1)
        t += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
    open(f, 'w', encoding='utf-8').write(t)
