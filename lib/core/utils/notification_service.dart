import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:logging/logging.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

/// #312: Service for scheduling daily meal reminder notifications.
class NotificationService {
  static const int _dailyReminderId = 0;
  static const String _channelId = 'daily_reminder';
  static const String _channelName = 'Daily Reminders';
  static const String _channelDesc = 'Daily meal logging reminder';

  final _log = Logger('NotificationService');
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Initializes the plugin. Must be called before any other method.
  Future<void> initialize() async {
    if (_initialized) return;
    tz.initializeTimeZones();
    final String timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const initSettings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);

    await _plugin.initialize(initSettings);
    _initialized = true;
    _log.fine('NotificationService initialized');
  }

  /// Requests the OS notification permission (Android 13+ / iOS).
  Future<bool> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final granted = await ios.requestPermissions(
          alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    return false;
  }

  /// Schedules a daily recurring notification at [hour]:[minute].
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    await _ensureInitialized();
    await _plugin.cancel(_dailyReminderId);

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const iosDetails = DarwinNotificationDetails();
    final details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);

    final scheduledDate = computeNextOccurrence(
      tz.TZDateTime.now(tz.local),
      hour,
      minute,
    );

    await _plugin.zonedSchedule(
      _dailyReminderId,
      title,
      body,
      scheduledDate,
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
    _log.fine('Daily reminder scheduled at $hour:$minute');
  }

  /// Cancels any pending daily reminder.
  Future<void> cancelDailyReminder() async {
    await _ensureInitialized();
    await _plugin.cancel(_dailyReminderId);
    _log.fine('Daily reminder cancelled');
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) await initialize();
  }

  /// Returns the next [tz.TZDateTime] at [hour]:[minute] in the same location
  /// as [now]. If today's slot has already passed (or matches `now` exactly),
  /// rolls forward to the next day. Pure function — extracted from
  /// [scheduleDailyReminder] so it can be unit-tested across timezones / DST
  /// transitions without touching the notification plugin.
  static tz.TZDateTime computeNextOccurrence(
    tz.TZDateTime now,
    int hour,
    int minute,
  ) {
    var scheduled = tz.TZDateTime(
        now.location, now.year, now.month, now.day, hour, minute);
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}
