import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// غيّر الرابط أو مرّره بـ --dart-define=SUPABASE_URL=...
const supabaseUrl = 'https://qrlgzwmqpfdskrwkbark.supabase.co';
const bucket = 'wird';
const appVersion = 'v8';

AndroidScheduleMode scheduleMode = AndroidScheduleMode.exactAllowWhileIdle;

// إن لم يجد النظام ملف الصوت المخصص نرجع تلقائياً إلى الصوت الافتراضي
bool customSound = true;

Future<void> withSoundFallback(Future<void> Function() f) async {
  for (var i = 0; i < 3; i++) {
    try {
      await f();
      return;
    } on PlatformException catch (e) {
      if (e.code == 'invalid_sound' && customSound) {
        customSound = false;
        continue;
      }
      if (e.code == 'exact_alarms_not_permitted' &&
          scheduleMode == AndroidScheduleMode.exactAllowWhileIdle) {
        scheduleMode = AndroidScheduleMode.inexactAllowWhileIdle;
        continue;
      }
      rethrow;
    }
  }
}

NotificationDetails _details(String body) => NotificationDetails(
      android: AndroidNotificationDetails(
        customSound ? 'wird_alert_v3' : 'wird_alert_v3_default',
        'تنبيه الورد اليومي',
        channelDescription: 'تنبيه بارز بصوت لتذكيرك بالورد اليومي',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        playSound: true,
        sound: customSound ? const RawResourceAndroidNotificationSound('wird_alert') : null,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 700, 300, 700, 300, 700]),
        visibility: NotificationVisibility.public,
        color: const Color(0xFF1B6B5A),
        ticker: 'وردك اليومي',
        styleInformation: BigTextStyleInformation(
          '$body\n\nافتح التطبيق لتراجع وردك، ثم سجّل الإنجاز.',
          contentTitle: 'وردك القرآني اليومي',
          summaryText: 'حان وقت الورد',
        ),
        actions: const [
          AndroidNotificationAction('no', 'لا', showsUserInterface: true),
          AndroidNotificationAction('done', doneText, showsUserInterface: true),
        ],
      ),
    );

Future<void> scheduleAll() async {
  try {
    await withSoundFallback(_scheduleAllImpl);
  } catch (_) {}
}

Future<void> _scheduleAllImpl() async {
  final p = await SharedPreferences.getInstance();
  await plugin.cancelAll();
  final h = p.getInt('h') ?? 6, m = p.getInt('m') ?? 0;
  final doneDay = p.getString('done');
  final now = tz.TZDateTime.now(tz.local);
  String? first;
  for (var d = 0; d < 7; d++) {
    final base = tz.TZDateTime(tz.local, now.year, now.month, now.day + d, h, m);
    for (var k = 0; k < 5; k++) {
      final t = base.add(Duration(hours: 2 * k));
      if (!t.isAfter(now)) continue;
      if (dayKey(t) == doneDay) continue;
      await plugin.zonedSchedule(
        d * 10 + k,
        'وردك اليومي',
        k == 0 ? 'هل راجعت وردك اليومي؟' : 'تذكير: هل راجعت وردك اليومي؟',
        t,
        _details(k == 0 ? 'هل راجعت وردك اليومي؟' : 'تذكير: هل راجعت وردك اليومي؟'),
        androidScheduleMode: scheduleMode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: 'wird',
      );
      first ??= t.toString();
    }
  }
  await p.setString('next', first ?? 'لا يوجد');
}

Future<void> postponeTwoHours() async {
  final t = tz.TZDateTime.now(tz.local).add(const Duration(hours: 2));
  await plugin.zonedSchedule(
    900,
    'وردك اليومي',
    'حان موعد المراجعة المؤجلة. هل راجعت وردك؟',
    t,
    _details('حان موعد المراجعة المؤجلة. هل راجعت وردك؟'),
    androidScheduleMode: scheduleMode,
    uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
    payload: 'wird',
  );
}

void _setLocalZone() {
  final off = DateTime.now().timeZoneOffset;
  tz.Location? pick;
  try {
    final cairo = tz.getLocation('Africa/Cairo');
    if (tz.TZDateTime.now(cairo).timeZoneOffset == off) pick = cairo;
  } catch (_) {}
  pick ??= tz.timeZoneDatabase.locations.values.firstWhere(
    (l) => tz.TZDateTime.now(l).timeZoneOffset == off,
    orElse: () => tz.UTC,
  );
  tz.setLocalLocation(pick);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (d) => Material(
      child: Center(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('حدث خطأ: ${d.exception}', textDirection: TextDirection.rtl))));
  runApp(const WirdApp());
  initNotifications();
}

Future<void> initNotifications() async {
  try {
    tzdata.initializeTimeZones();
    _setLocalZone();
  } catch (_) {}
  try {
    await plugin.initialize(
      const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: onResp,
    );
    final launch = await plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      actionNotifier.value = launch!.notificationResponse?.actionId ?? 'open';
    }
  } catch (_) {}
  try {
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  } catch (_) {}
  await scheduleAll();
}

class WirdApp extends StatelessWidget {
  const WirdApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'الورد اليومي',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF1B6B5A),
          scaffoldBackgroundColor: const Color(0xFFFAF7F0),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  String? loadedDay;
  Map<String, dynamic>? data;
  String status = 'جاري التحميل...';
  bool done = false;
  final player = AudioPlayer();
  String? current;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    actionNotifier.addListener(_onAction);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAction());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    actionNotifier.removeListener(_onAction);
    player.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (loadedDay != dayKey(DateTime.now())) {
        player.stop();
        current = null;
        data = null;
        done = false;
        status = 'جاري التحميل...';
        if (mounted) setState(() {});
      }
      _load();
      scheduleAll();
    }
  }

  Future<File> _jsonFile(String key) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/wird_$key.json');
  }

  Future<File> _audioFile(String day, String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/wird_${day}_$name.audio');
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final key = dayKey(DateTime.now());
    loadedDay = key;
    done = p.getString('done') == key;
    final f = await _jsonFile(key);
    if (await f.exists()) {
      data = jsonDecode(await f.readAsString());
      status = '';
      if (mounted) setState(() {});
    }
    await _sync(key, f);
  }

  Future<void> _sync(String key, File f) async {
    try {
      var r = await http
          .get(Uri.parse('$supabaseUrl/storage/v1/object/public/$bucket/daily/$key.json'))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        // الملف لم يُجهَّز بعد: اطلب من الدالة أن تبنيه الآن
        r = await http
            .get(Uri.parse('$supabaseUrl/functions/v1/sync-wird?date=$key'))
            .timeout(const Duration(seconds: 30));
      }
      if (r.statusCode == 200) {
        final body = utf8.decode(r.bodyBytes);
        await f.writeAsString(body);
        data = jsonDecode(body);
        status = '';
        if (mounted) setState(() {});
        for (final t in (data!['tracks'] as List? ?? [])) {
          final af = await _audioFile(key, t['key']);
          if (!await af.exists()) {
            final ar = await http.get(Uri.parse(t['url']));
            if (ar.statusCode == 200) await af.writeAsBytes(ar.bodyBytes);
          }
        }
      } else if (data == null) {
        status = 'لم يُرفع ورد اليوم بعد.';
      }
    } catch (e) {
      if (data == null) status = 'تعذر الاتصال بالخادم.\n\n$e';
    }
    if (mounted) setState(() {});
  }

  Future<void> _markDone() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('done', dayKey(DateTime.now()));
    await scheduleAll();
    if (!mounted) return;
    setState(() => done = true);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تقبّل الله منك. تم تسجيل الإنجاز.')));
  }

  void _onAction() {
    final a = actionNotifier.value;
    if (a == null) return;
    actionNotifier.value = null;
    if (a == 'done') {
      _markDone();
    } else if (a == 'no') {
      _askReviewOrPostpone();
    } else if (a == 'open') {
      _askDone();
    }
  }

  void _askDone() {
    if (!mounted || done) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('هل راجعت وردك اليومي؟'),
        actions: [
          TextButton(
              onPressed: () {
                Navigator.pop(c);
                _askReviewOrPostpone();
              },
              child: const Text('لا')),
          FilledButton(
              onPressed: () {
                Navigator.pop(c);
                _markDone();
              },
              child: const Text(doneText)),
        ],
      ),
    );
  }

  void _askReviewOrPostpone() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('لم تراجع وردك بعد'),
        content: const Text('هل تبدأ المراجعة الآن أم تؤجلها ساعتين؟'),
        actions: [
          TextButton(
              onPressed: () async {
                Navigator.pop(c);
                await withSoundFallback(postponeTwoHours);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('سيتم تذكيرك بعد ساعتين.')));
                }
              },
              child: const Text('تأجيل ساعتين')),
          FilledButton(onPressed: () => Navigator.pop(c), child: const Text('مراجعة الآن')),
        ],
      ),
    );
  }

  Future<void> _toggle(Map t) async {
    final name = t['key'] as String;
    if (current == name) {
      player.playing ? await player.pause() : await player.play();
      return;
    }
    try {
      final af = await _audioFile(dayKey(DateTime.now()), name);
      if (await af.exists()) {
        await player.setFilePath(af.path);
      } else {
        await player.setUrl(t['url']);
      }
      current = name;
      await player.play();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('تعذر تشغيل الملف الصوتي.')));
      }
    }
  }

  Widget _trackCard(Map t) {
    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (c, s) {
        final isCur = current == t['key'];
        final playing = isCur &&
            (s.data?.playing ?? false) &&
            s.data?.processingState != ProcessingState.completed;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              ListTile(
                title: Text(t['title'], style: const TextStyle(fontSize: 20)),
                trailing: IconButton(
                  iconSize: 44,
                  icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                  onPressed: () => _toggle(t),
                ),
              ),
              if (isCur)
                StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (c, ps) {
                    final dur = player.duration?.inMilliseconds ?? 0;
                    final pos = ps.data?.inMilliseconds ?? 0;
                    return LinearProgressIndicator(value: dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0);
                  },
                ),
            ]),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracks = (data?['tracks'] as List?) ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('ورد اليوم'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: data == null
          ? Center(
              child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16))))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final t in tracks) _trackCard(t as Map),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: done ? null : _markDone,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                  child: Text(done ? 'تم تسجيل وردك اليوم ✓' : doneText,
                      textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TimeOfDay t = const TimeOfDay(hour: 6, minute: 0);
  String info = 'جاري الفحص...';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      setState(() => t = TimeOfDay(hour: p.getInt('h') ?? 6, minute: p.getInt('m') ?? 0));
    });
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final impl = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final enabled = await impl?.areNotificationsEnabled();
      final pending = await plugin.pendingNotificationRequests();
      final p = await SharedPreferences.getInstance();
      info = 'الإصدار: $appVersion\n'
          'الإشعارات مسموحة: ${enabled == true ? "نعم" : "لا"}\n'
          'عدد الإشعارات المجدولة: ${pending.length}\n'
          'المنطقة الزمنية: ${tz.local.name}\n'
          'الوقت الآن: ${tz.TZDateTime.now(tz.local)}\n'
          'أقرب تذكير: ${p.getString('next') ?? '—'}\n'
          'تم تسجيل ورد اليوم: ${p.getString('done') == dayKey(DateTime.now()) ? 'نعم' : 'لا'}';
    } catch (e) {
      info = 'الإصدار: $appVersion\nخطأ في الفحص: $e';
    }
    if (mounted) setState(() {});
  }

  void _msg(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('الإعدادات')),
        body: ListView(
          padding: const EdgeInsets.all(8),
          children: [
            ListTile(
              title: const Text('وقت بدء التذكير اليومي'),
              subtitle: Text(t.format(context)),
              trailing: const Icon(Icons.access_time),
              onTap: () async {
                final r = await showTimePicker(context: context, initialTime: t);
                if (r == null) return;
                final p = await SharedPreferences.getInstance();
                await p.setInt('h', r.hour);
                await p.setInt('m', r.minute);
                await scheduleAll();
                setState(() => t = r);
                _refresh();
              },
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(info, style: const TextStyle(fontSize: 15, height: 1.7)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OutlinedButton(
                onPressed: () async {
                  try {
                    await plugin
                        .resolvePlatformSpecificImplementation<
                            AndroidFlutterLocalNotificationsPlugin>()
                        ?.requestNotificationsPermission();
                    await scheduleAll();
                  } catch (e) {
                    _msg('$e');
                  }
                  _refresh();
                },
                child: const Text('طلب إذن الإشعارات وإعادة الجدولة'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OutlinedButton(
                onPressed: () async {
                  try {
                    await withSoundFallback(() => plugin.show(
                        951,
                        'وردك القرآني اليومي',
                        'هل راجعت وردك اليومي؟',
                        _details('هل راجعت وردك اليومي؟'),
                        payload: 'wird'));
                  } catch (e) {
                    _msg('$e');
                  }
                },
                child: const Text('إشعار تجريبي فوري'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OutlinedButton(
                onPressed: () async {
                  try {
                    final when =
                        tz.TZDateTime.now(tz.local).add(const Duration(minutes: 1));
                    await withSoundFallback(() => plugin.zonedSchedule(
                      950,
                      'وردك القرآني اليومي',
                      'هل راجعت وردك اليومي؟',
                      when,
                      _details('إشعار مجدول تجريبي'),
                      androidScheduleMode: scheduleMode,
                      uiLocalNotificationDateInterpretation:
                          UILocalNotificationDateInterpretation.absoluteTime,
                      payload: 'wird',
                    ));
                    _msg('سيصلك إشعار بعد نحو دقيقة. أغلق التطبيق وانتظر.');
                  } catch (e) {
                    _msg('$e');
                  }
                  _refresh();
                },
                child: const Text('إشعار مجدول بعد دقيقة'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: OutlinedButton(
                onPressed: () async {
                  final p = await SharedPreferences.getInstance();
                  await p.remove('done');
                  await scheduleAll();
                  _msg('أُلغي تسجيل إنجاز اليوم وأُعيدت الجدولة.');
                  _refresh();
                },
                child: const Text('إلغاء تسجيل إنجاز اليوم (للتجربة)'),
              ),
            ),
          ],
        ),
      );
}
