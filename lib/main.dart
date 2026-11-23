import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
const doneText = 'الحمد لله الذي بنعمته تتم الصالحات';

final plugin = FlutterLocalNotificationsPlugin();
final actionNotifier = ValueNotifier<String?>(null);

String two(int n) => n.toString().padLeft(2, '0');
String dayKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

void onResp(NotificationResponse r) {
  actionNotifier.value = r.actionId ?? 'open';
}

const androidDetails = AndroidNotificationDetails(
  'wird_channel',
  'تذكير الورد اليومي',
  importance: Importance.max,
  priority: Priority.max,
  fullScreenIntent: true,
  category: AndroidNotificationCategory.alarm,
  visibility: NotificationVisibility.public,
  actions: [
    AndroidNotificationAction('no', 'لا', showsUserInterface: true),
    AndroidNotificationAction('done', doneText, showsUserInterface: true),
  ],
);

String? lastScheduleError;

Future<void> scheduleAll() async {
  try {
    await _scheduleAllImpl();
    lastScheduleError = null;
  } catch (e) {
    lastScheduleError = '$e';
  }
}

// يحاول الجدولة الدقيقة أولاً، وإن رفضها النظام يرجع للجدولة غير الدقيقة.
Future<void> _zs(int id, String title, String body, tz.TZDateTime t) async {
  Future<void> go(AndroidScheduleMode mode) => plugin.zonedSchedule(
        id,
        title,
        body,
        t,
        const NotificationDetails(android: androidDetails),
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: 'wird',
      );
  try {
    await go(AndroidScheduleMode.exactAllowWhileIdle);
  } catch (_) {
    await go(AndroidScheduleMode.inexactAllowWhileIdle);
  }
}

Future<void> _scheduleAllImpl() async {
  final p = await SharedPreferences.getInstance();
  await plugin.cancelAll();
  final h = p.getInt('h') ?? 6, m = p.getInt('m') ?? 0;
  final doneDay = p.getString('done');
  final now = tz.TZDateTime.now(tz.local);
  for (var d = 0; d < 7; d++) {
    final base = tz.TZDateTime(tz.local, now.year, now.month, now.day + d, h, m);
    for (var k = 0; k < 5; k++) {
      final t = base.add(Duration(hours: 2 * k));
      if (!t.isAfter(now)) continue;
      if (dayKey(t) == doneDay) continue;
      await _zs(
        d * 10 + k,
        'وردك اليومي',
        k == 0 ? 'هل راجعت وردك اليومي؟' : 'تذكير: هل راجعت وردك اليومي؟',
        t,
      );
    }
  }
}

Future<void> postponeTwoHours() async {
  final t = tz.TZDateTime.now(tz.local).add(const Duration(hours: 2));
  await _zs(900, 'وردك اليومي', 'حان موعد المراجعة المؤجلة. هل راجعت وردك؟', t);
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
  try {
    final a = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final p = await SharedPreferences.getInstance();
    if (p.getBool('fsAsked') != true) {
      await p.setBool('fsAsked', true);
      await a?.requestFullScreenIntentPermission();
    }
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

class _HomePageState extends State<HomePage> {
  Map<String, dynamic>? data;
  String status = 'جاري التحميل...';
  bool done = false;
  final player = AudioPlayer();
  String? current;
  Future<void>? _loading;
  bool _reminderOpen = false;

  @override
  void initState() {
    super.initState();
    actionNotifier.addListener(_onAction);
    _loading = _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAction());
  }

  @override
  void dispose() {
    actionNotifier.removeListener(_onAction);
    player.dispose();
    super.dispose();
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
      final r = await http
          .get(Uri.parse('$supabaseUrl/storage/v1/object/public/$bucket/daily/$key.json'))
          .timeout(const Duration(seconds: 20));
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
    } else {
      _showReminder();
    }
  }

  // يظهر عند فتح الإشعار (أو تلقائيًا فوق الشاشة): نص و/أو صوت حسب اختيار المستخدم.
  Future<void> _showReminder() async {
    if (!mounted || _reminderOpen) return;
    final p = await SharedPreferences.getInstance();
    final mode = p.getString('mode') ?? 'both';
    if (p.getString('done') == dayKey(DateTime.now())) return;
    _reminderOpen = true;
    final wantSound = mode == 'sound' || mode == 'both';
    final wantText = mode == 'text' || mode == 'both';
    if (wantSound) {
      try {
        await _loading;
      } catch (_) {}
      final tracks = (data?['tracks'] as List?) ?? [];
      if (tracks.isNotEmpty) {
        current = null;
        await _toggle(tracks.first as Map);
      }
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('وردك اليومي'),
        content: Text(wantText
            ? 'هل راجعت وردك اليومي؟'
            : 'يتم تشغيل وردك الآن. هل راجعته؟'),
        actions: [
          TextButton(
              onPressed: () {
                Navigator.pop(c);
                player.pause();
                _askReviewOrPostpone();
              },
              child: const Text('لا')),
          FilledButton(
              onPressed: () {
                Navigator.pop(c);
                player.pause();
                _markDone();
              },
              child: const Text(doneText, textAlign: TextAlign.center)),
        ],
      ),
    );
    _reminderOpen = false;
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
                await postponeTwoHours();
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
  String mode = 'both';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      setState(() {
        t = TimeOfDay(hour: p.getInt('h') ?? 6, minute: p.getInt('m') ?? 0);
        mode = p.getString('mode') ?? 'both';
      });
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('الإعدادات')),
        body: ListView(children: [
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
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('طريقة التنبيه عند فتح الإشعار', style: TextStyle(fontSize: 16)),
          ),
          RadioListTile<String>(
              title: const Text('نص فقط'),
              value: 'text',
              groupValue: mode,
              onChanged: _setMode),
          RadioListTile<String>(
              title: const Text('صوت فقط'),
              value: 'sound',
              groupValue: mode,
              onChanged: _setMode),
          RadioListTile<String>(
              title: const Text('نص وصوت معًا'),
              value: 'both',
              groupValue: mode,
              onChanged: _setMode),
          ListTile(
            title: const Text('اختبار الإشعارات'),
            subtitle: const Text('يرسل إشعارًا فوريًا ويعرض حالة الجدولة'),
            trailing: const Icon(Icons.notifications_active_outlined),
            onTap: _testNotifications,
          ),
        ]),
      );

  Future<void> _setMode(String? v) async {
    if (v == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('mode', v);
    setState(() => mode = v);
  }

  Future<void> _testNotifications() async {
    final lines = <String>[];
    try {
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      var enabled = await android?.areNotificationsEnabled();
      if (enabled != true) {
        enabled = await android?.requestNotificationsPermission();
      }
      lines.add('إذن الإشعارات: ${enabled == true ? "مفعّل" : "مغلق (فعّله من إعدادات الهاتف)"}');
      final exact = await android?.canScheduleExactNotifications();
      lines.add('المنبهات الدقيقة: ${exact == true ? "مسموحة" : "غير مسموحة (سيتم استخدام الجدولة التقريبية)"}');
      await plugin.show(999, 'وردك اليومي', 'هذا إشعار تجريبي ✓',
          const NotificationDetails(android: androidDetails));
      await scheduleAll();
      final pending = await plugin.pendingNotificationRequests();
      lines.add('إشعارات مجدولة: ${pending.length}');
      lines.add('المنطقة الزمنية: ${tz.local.name}');
      if (lastScheduleError != null) lines.add('خطأ الجدولة: $lastScheduleError');
    } catch (e) {
      lines.add('خطأ: $e');
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('حالة الإشعارات'),
        content: Text(lines.join('\n')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('حسنًا'))],
      ),
    );
  }
}
