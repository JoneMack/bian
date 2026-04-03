import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/strategy_snapshot.dart';

class NotificationService {
  NotificationService._();

  static const _lastDigestKey = 'latest_entry_alert_digest_v1';
  static const _lastAtKey = 'latest_entry_alert_at_v1';
  static const _dedupeWindow = Duration(hours: 6);
  static const _notificationId = 4201;

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized || kIsWeb || !_supportsLocalNotifications) return;

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        defaultPresentAlert: true,
        defaultPresentBadge: true,
        defaultPresentSound: true,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        defaultPresentAlert: true,
        defaultPresentBadge: true,
        defaultPresentSound: true,
      ),
    );

    await _plugin.initialize(settings);
    _initialized = true;
  }

  Future<void> requestPermissions() async {
    if (kIsWeb || !_supportsLocalNotifications) return;
    await initialize();

    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
    await _plugin
        .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<bool> notifyEntrySignals(
    List<EntryAlertSignal> alerts, {
    String? presetLabel,
  }) async {
    if (kIsWeb || !_supportsLocalNotifications) return false;

    final actionable = alerts
        .where((alert) => alert.shouldNotify)
        .take(3)
        .toList()
      ..sort((a, b) => b.totalScore.compareTo(a.totalScore));
    if (actionable.isEmpty) return false;

    await initialize();
    await requestPermissions();

    final prefs = await SharedPreferences.getInstance();
    final digest = _digest(actionable);
    final previousDigest = prefs.getString(_lastDigestKey);
    final previousAt = DateTime.tryParse(prefs.getString(_lastAtKey) ?? '');
    final now = DateTime.now();

    final isDuplicate = previousDigest == digest &&
        previousAt != null &&
        now.difference(previousAt) < _dedupeWindow;
    if (isDuplicate) {
      return false;
    }

    final title = actionable.length == 1
        ? '${actionable.first.symbol} ${actionable.first.timingLabel}'
        : '发现 ${actionable.length} 个买点信号';
    final body = actionable
        .map((alert) =>
            '${alert.symbol} ${(alert.totalScore * 100).round()}分 ${alert.timingLabel}')
        .join(' / ');

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'entry_signals',
        '入场提醒',
        channelDescription: '高概率买点推送',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.active,
        threadIdentifier: 'entry-signals',
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        threadIdentifier: 'entry-signals',
      ),
    );

    final payload = jsonEncode({
      'presetLabel': presetLabel ?? '',
      'generatedAt': now.toIso8601String(),
      'alerts': actionable.map((alert) => alert.toJson()).toList(),
    });

    await _plugin.show(
      _notificationId,
      title,
      presetLabel == null || presetLabel.isEmpty
          ? body
          : '$presetLabel | $body',
      details,
      payload: payload,
    );

    await prefs.setString(_lastDigestKey, digest);
    await prefs.setString(_lastAtKey, now.toIso8601String());
    return true;
  }

  bool get _supportsLocalNotifications {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return true;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return false;
    }
  }

  String _digest(List<EntryAlertSignal> alerts) {
    return alerts
        .map((alert) => '${alert.symbol}:${alert.timingLabel}')
        .join('|');
  }
}
