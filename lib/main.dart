import 'dart:convert';
import 'dart:io';
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
const doneText = 'الحمد لله الذي بنعمته تتم الصالحات';

final plugin = FlutterLocalNotificationsPlugin();
final actionNotifier = ValueNotifier<String?>(null);

String two(int n) => n.toString().padLeft(2, '0');
String dayKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

void onResp(NotificationResponse r) {
  actionNotifier.value = r.actionId ?? 'open';
}

// طريقة التنبيه الحالية (text | sound | both). تُقرأ من الإعدادات قبل أي جدولة.
String alertMode = 'both';

// القناة (channel) في أندرويد تثبّت إعداد الصوت عند إنشائها،
// لذلك لكل وضع قناة مستقلة بمعرّف جديد.
AndroidNotificationDetails currentDetails() {
  final withSound = alertMode != 'text';
  return AndroidNotificationDetails(
    withSound ? 'wird_channel_v2' : 'wird_channel_silent_v2',
    withSound ? 'تذكير الورد اليومي (بصوت)' : 'تذكير الورد اليومي (بدون صوت)',
    importance: Importance.max,
    priority: Priority.max,
    fullScreenIntent: true,
    category: AndroidNotificationCategory.alarm,
    visibility: NotificationVisibility.public,
    playSound: withSound,
    sound: withSound ? const RawResourceAndroidNotificationSound('wird_alert') : null,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration: true,
    actions: const [
      AndroidNotificationAction('no', 'لا', showsUserInterface: true),
      AndroidNotificationAction('done', doneText, showsUserInterface: true),
    ],
  );
}

Future<void> loadAlertMode() async {
  final p = await SharedPreferences.getInstance();
  alertMode = p.getString('mode') ?? 'both';
}

// ---------- الجدولة ----------

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
        NotificationDetails(android: currentDetails()),
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
  alertMode = p.getString('mode') ?? 'both';
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
  await loadAlertMode();
  final t = tz.TZDateTime.now(tz.local).add(const Duration(hours: 2));
  await _zs(900, 'وردك اليومي', 'حان موعد المراجعة المؤجلة. هل راجعت وردك؟', t);
}

// يسجّل إنجاز اليوم (للسجل ولإيقاف تذكيرات اليوم)
Future<void> recordDone() async {
  final p = await SharedPreferences.getInstance();
  final k = dayKey(DateTime.now());
  await p.setString('done', k);
  final days = p.getStringList('doneDays') ?? <String>[];
  if (!days.contains(k)) {
    days.add(k);
    await p.setStringList('doneDays', days);
  }
  await scheduleAll();
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

// ---------- ملفات محلية ----------

Future<File> jsonFile(String key) async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/wird_$key.json');
}

Future<File> audioFile(String day, String name) async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/wird_${day}_$name.audio');
}

// ---------- بدء التطبيق ----------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (d) => Material(
      child: Center(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('حدث خطأ: ${d.exception}', textDirection: TextDirection.rtl))));
  await initNotificationsCore();
  runApp(const WirdApp());
  setupNotifications();
}

// تهيئة سريعة قبل رسم الشاشة، لنعرف هل فُتح التطبيق من إشعار.
Future<void> initNotificationsCore() async {
  try {
    final p = await SharedPreferences.getInstance();
    if (p.getString('first') == null) {
      await p.setString('first', dayKey(DateTime.now()));
    }
  } catch (_) {}
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
}

Future<void> setupNotifications() async {
  final a = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  try {
    await a?.deleteNotificationChannel('wird_channel');
  } catch (_) {}
  try {
    await a?.requestNotificationsPermission();
  } catch (_) {}
  try {
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
        home: const Root(),
      );
}

// يعرض رسالة التذكير بملء الشاشة إذا جاء المستخدم من إشعار، وإلا الصفحة الرئيسية.
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  String? reminder;

  String? _take() {
    final a = actionNotifier.value;
    actionNotifier.value = null;
    return a;
  }

  void _check() {
    final a = _take();
    if (a != null && mounted) setState(() => reminder = a);
  }

  @override
  void initState() {
    super.initState();
    reminder = _take();
    actionNotifier.addListener(_check);
  }

  @override
  void dispose() {
    actionNotifier.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => reminder == null
      ? const HomePage()
      : ReminderScreen(
          key: ValueKey(reminder),
          action: reminder!,
          onOpenApp: () => setState(() => reminder = null),
        );
}

// ---------- شاشة التذكير ----------

class ReminderScreen extends StatefulWidget {
  final String action; // open | no | done
  final VoidCallback onOpenApp;
  const ReminderScreen({super.key, required this.action, required this.onOpenApp});
  @override
  State<ReminderScreen> createState() => _ReminderScreenState();
}

class _ReminderScreenState extends State<ReminderScreen> {
  late String stage; // ask | review
  String mode = 'both';
  final player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    stage = widget.action == 'no' ? 'review' : 'ask';
    if (widget.action == 'done') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _done());
    } else {
      _init();
    }
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    mode = p.getString('mode') ?? 'both';
    if (p.getString('done') == dayKey(DateTime.now())) {
      widget.onOpenApp();
      return;
    }
    if (mounted) setState(() {});
    // لا تشغيل تلقائي للآيات: التنبيه الصوتي يأتي من نغمة الإشعار،
    // والاستماع للورد بزر يضغطه المستخدم.
  }

  bool listening = false;

  Future<void> _toggleListen() async {
    if (listening) {
      await player.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    setState(() => listening = true);
    final found = await _play();
    if (!mounted) return;
    setState(() => listening = false);
    if (!found) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد ملف صوتي لورد اليوم بعد.')));
    }
  }

  Future<bool> _play() async {
    try {
      final key = dayKey(DateTime.now());
      final f = await jsonFile(key);
      if (!await f.exists()) return false;
      final tracks = (jsonDecode(await f.readAsString())['tracks'] as List?) ?? [];
      if (tracks.isEmpty) return false;
      final t = tracks.first as Map;
      final af = await audioFile(key, t['key']);
      if (await af.exists()) {
        await player.setFilePath(af.path);
      } else {
        await player.setUrl(t['url']);
      }
      await player.play();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _closeApp() async {
    try {
      await player.stop();
    } catch (_) {}
    await SystemNavigator.pop();
  }

  Future<void> _done() async {
    await recordDone();
    await _closeApp();
  }

  Future<void> _no() async {
    await player.stop();
    if (mounted) setState(() => stage = 'review');
  }

  Future<void> _reviewNow() async {
    await player.stop();
    widget.onOpenApp();
  }

  Future<void> _later() async {
    await postponeTwoHours();
    await _closeApp();
  }

  Widget _btn(String text, VoidCallback onTap, {bool filled = true}) {
    final style = const EdgeInsets.symmetric(vertical: 18);
    final child = Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 19));
    return SizedBox(
      width: double.infinity,
      child: filled
          ? FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(padding: style),
              child: child)
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(padding: style),
              child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ask = stage == 'ask';
    final showText = ask ? mode != 'sound' : true;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.primaryContainer,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(ask && mode == 'sound' ? Icons.volume_up : Icons.menu_book,
                  size: 96, color: cs.primary),
              const SizedBox(height: 28),
              if (showText)
                Text(
                  ask ? 'هل راجعت وردك اليومي؟' : 'هل تود المراجعة الآن؟',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
                )
              else
                const Text('وردك اليومي',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 48),
              if (ask) ...[
                _btn(doneText, _done),
                const SizedBox(height: 16),
                _btn('لا', _no, filled: false),
                const SizedBox(height: 16),
                _btn(listening ? 'إيقاف الاستماع' : 'استمع للورد', _toggleListen,
                    filled: false),
              ] else ...[
                _btn('نعم', _reviewNow),
                const SizedBox(height: 16),
                _btn('لاحقًا (بعد ساعتين)', _later, filled: false),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- الصفحة الرئيسية ----------

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
  List<MapEntry<String, bool>> log = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  Future<void> _loadLog() async {
    final p = await SharedPreferences.getInstance();
    final days = (p.getStringList('doneDays') ?? <String>[]).toSet();
    final today = DateTime.now();
    final first = p.getString('first') ?? dayKey(today);
    final out = <MapEntry<String, bool>>[];
    for (var i = 0; i < 30; i++) {
      final k = dayKey(DateTime(today.year, today.month, today.day - i));
      if (k.compareTo(first) < 0) break;
      out.add(MapEntry(k, days.contains(k) || (i == 0 && p.getString('done') == k)));
    }
    log = out;
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final key = dayKey(DateTime.now());
    done = p.getString('done') == key;
    await _loadLog();
    final f = await jsonFile(key);
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
          final af = await audioFile(key, t['key']);
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
    await recordDone();
    if (!mounted) return;
    setState(() => done = true);
    await _loadLog();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تقبّل الله منك. تم تسجيل الإنجاز.')));
  }

  Future<void> _toggle(Map t) async {
    final name = t['key'] as String;
    if (current == name) {
      player.playing ? await player.pause() : await player.play();
      return;
    }
    try {
      final af = await audioFile(dayKey(DateTime.now()), name);
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

  Widget _logCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('سجل الإنجاز',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final e in log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Text(e.key, style: const TextStyle(fontSize: 16)),
                const Spacer(),
                Icon(e.value ? Icons.check_circle : Icons.cancel,
                    size: 20, color: e.value ? Colors.green : Colors.red.shade400),
                const SizedBox(width: 6),
                Text(e.value ? 'تم' : 'لم يتم',
                    style: TextStyle(
                        fontSize: 16,
                        color: e.value ? Colors.green.shade700 : Colors.red.shade400)),
              ]),
            ),
        ]),
      ),
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (data == null)
            Padding(
                padding: const EdgeInsets.all(20),
                child: Text(status,
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 16))),
          for (final t in tracks) _trackCard(t as Map),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: done ? null : _markDone,
            style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
            child: Text(done ? 'تم تسجيل وردك اليوم ✓' : doneText,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
          ),
          const SizedBox(height: 16),
          _logCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ---------- الإعدادات ----------

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

  Future<void> _setMode(String? v) async {
    if (v == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('mode', v);
    setState(() => mode = v);
    await scheduleAll();
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
      await scheduleAll();
      final pending = await plugin.pendingNotificationRequests();
      lines.add('إشعارات مجدولة: ${pending.length}');
      lines.add('المنطقة الزمنية: ${tz.local.name}');
      if (lastScheduleError != null) lines.add('خطأ الجدولة: $lastScheduleError');
      await plugin.show(999, 'وردك اليومي', 'هذا إشعار تجريبي ✓',
          NotificationDetails(android: currentDetails()), payload: 'wird');
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
            child: Text('طريقة التنبيه', style: TextStyle(fontSize: 16)),
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
}
