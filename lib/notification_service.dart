import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class NotificationService {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    final DarwinInitializationSettings initializationSettingsIOS =
        DarwinInitializationSettings();

    final InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await flutterLocalNotificationsPlugin.initialize(initializationSettings);

    tz.initializeTimeZones();
  }

  Future<void> requestPermissions() async {
    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidImplementation != null) {
      await androidImplementation.requestNotificationsPermission();
    }

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
  }

  Future<Map<String, String>> _fetchQuote() async {
    final response = await http.get(Uri.parse('https://api.quotable.io/random'));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {
        'content': data['content'],
        'author': data['author'],
      };
    } else {
      throw Exception('Failed to load quote');
    }
  }

  Future<void> scheduleDailyQuoteNotification() async {
    final prefs = await SharedPreferences.getInstance();
    final bool isScheduled = prefs.getBool('isNotificationScheduled') ?? false;

    if (isScheduled) return;

    await requestPermissions();

    final quote = await _fetchQuote();

    await flutterLocalNotificationsPlugin.zonedSchedule(
      0,
      'Reflexión Diaria',
      '“${quote['content']}” - ${quote['author']}',
      _nextInstanceOfNineAM(),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_quote_channel',
          'Reflexiones Diarias',
          channelDescription: 'Canal para las reflexiones diarias',
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );

    await prefs.setBool('isNotificationScheduled', true);
  }

  tz.TZDateTime _nextInstanceOfNineAM() {
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduledDate =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, 9);
    if (scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }
}
