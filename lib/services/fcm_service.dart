import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../core/network/api_client.dart';
import '../data/models/models.dart';
import '../firebase_options.dart';
import '../providers/fcm_inbox_store.dart';
import '../providers/map_provider.dart';
import 'fcm_report_proximity.dart';
import 'nearby_report_alert.dart';

const _fcmChannelId = 'fcm_push';
const _fcmChannelName = '서버 알림';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // 백그라운드 isolate — local_notifications 동작에 플러그인 등록 필수
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('[FCM] bg data=${message.data}');

  // TODO: 테스트 후 복구 — report 타입이 아니면 알림 생략
  // if (!ReportItem.isFcmReportPush(message.data) &&
  //     ReportItem.fromFcmData(message.data) == null) {
  //   return;
  // }
  if (!await NearbyReportAlert.isGlobalNotificationsEnabled()) return;

  final report = ReportItem.fromFcmData(message.data);
  // 거리 무관 — 지도 임시 마커용으로 항상 적재
  if (report != null) {
    await MapProvider.persistPendingFcmReport(report);
    await NearbyReportAlert.markReportNotifiedPersist(report.id);
  }
  // 알림함은 400m 안일 때만
  if (report != null &&
      await FcmReportProximity.isReportWithinRadius(report)) {
    await FcmInboxStore.appendFromMessage(message);
  }

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_report_warning'),
      iOS: DarwinInitializationSettings(),
    ),
  );
  await _ensureFcmAndroidChannel(plugin);
  await _showReportNotification(plugin, message, report);
}

Future<void> _ensureFcmAndroidChannel(
  FlutterLocalNotificationsPlugin plugin,
) async {
  final androidImpl = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.createNotificationChannel(
    const AndroidNotificationChannel(
      _fcmChannelId,
      _fcmChannelName,
      description: '새로운 제보 등 서버 푸시',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    ),
  );
}

/// GPS 거리 계산을 기다리지 않고 즉시 배너를 띄운다.
Future<void> _showReportNotification(
  FlutterLocalNotificationsPlugin plugin,
  RemoteMessage message,
  ReportItem? report,
) async {
  final title = report != null
      ? NearbyReportAlert.formatReportAlertTitle(report)
      : (message.notification?.title ??
          message.data['title']?.toString() ??
          '알림');
  final body = report != null
      ? NearbyReportAlert.formatReportAlertBody(report)
      : (message.notification?.body ??
          message.data['body']?.toString() ??
          '새 알림이 있습니다');
  final notifId = report != null
      ? 10000 + (report.id.abs() % 1000000)
      : 80001;

  try {
    final androidImpl = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    var enabled = await androidImpl?.areNotificationsEnabled();
    debugPrint(
      '[FCM] show start id=$notifId enabled=$enabled '
      'title=$title androidImpl=${androidImpl != null}',
    );

    if (enabled == false) {
      debugPrint(
        '[FCM] 시스템 알림 권한 OFF — 배너가 표시되지 않습니다. '
        '설정 → 앱 → 안전지도 → 알림 허용을 켜 주세요.',
      );
      final granted =
          await androidImpl?.requestNotificationsPermission() ?? false;
      enabled = await androidImpl?.areNotificationsEnabled();
      debugPrint(
        '[FCM] permission re-request granted=$granted enabled=$enabled',
      );
      if (enabled == false) {
        debugPrint('[FCM] show aborted — notifications still disabled');
        return;
      }
    }

    await plugin.show(
      id: notifId,
      title: title,
      body: body,
      payload: report != null ? NearbyReportAlert.reportPayload(report.id) : null,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _fcmChannelId,
          _fcmChannelName,
          channelDescription: '새로운 제보 등 서버 푸시',
          icon: 'ic_stat_report_warning',
          color: const Color(0xFFDC2626),
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.alarm,
          styleInformation: BigTextStyleInformation(body, contentTitle: title),
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: true,
        ),
      ),
    );
    debugPrint('[FCM] show done id=$notifId');
  } catch (e, st) {
    debugPrint('[FCM] local notification show failed: $e\n$st');
  }
}

class FcmService {
  ApiClient? _api;
  FlutterLocalNotificationsPlugin? _plugin;
  FcmInboxStore? _inbox;
  MapProvider? _map;
  NearbyReportAlert? _nearbyAlert;

  Future<void> init({
    required ApiClient api,
    required FlutterLocalNotificationsPlugin localNotifications,
    required FcmInboxStore inbox,
  }) async {
    _api = api;
    _plugin = localNotifications;
    _inbox = inbox;

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _ensureFcmAndroidChannel(_plugin!);
    final androidImpl = _plugin!
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();

    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen(_handleForeground);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);

    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _handleTap(initial);

    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      _registerToken(token);
    });
  }

  void bindMap(MapProvider map) {
    _map = map;
  }

  void bindNearbyAlert(NearbyReportAlert alert) {
    _nearbyAlert = alert;
  }

  /// 로그인 직후 / hydrate 직후에 밖에서 호출
  Future<void> registerCurrentToken() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _registerToken(token);
  }

  /// 로그아웃 직후에 밖에서 호출
  Future<void> unregisterCurrentToken() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || _api == null) return;
    try {
      await _api!.patch(
        '/notification/unregister',
        body: {'fcmToken': token},
      );
    } catch (_) {}
  }

  Future<void> _registerToken(String token) async {
    final api = _api;
    if (api == null) return;
    final accessToken = await api.getAccessToken();
    if (accessToken == null) return;
    try {
      await api.post(
        '/notification/register',
        body: {
          'fcmToken': token,
          'device_type': Platform.isAndroid ? 'android' : 'ios',
        },
      );
    } catch (e) {
      debugPrint('FCM Token 등록 실패: $e');
    }
  }

  Future<void> _onReportPush(RemoteMessage message, ReportItem report) async {
    debugPrint(
      '[FCM] apply marker id=${report.id} lat=${report.lat} lng=${report.lng}',
    );
    // 거리 무관 — 지도 임시 마커. 포그라운드 즉시 + prefs 백업(백그라운드/재개 복원).
    _map?.upsertReportFromPush(report);
    await MapProvider.persistPendingFcmReport(report);
    await _nearbyAlert?.markReportNotified(report.id);
    if (await FcmReportProximity.isReportWithinRadius(report)) {
      await _inbox?.addFromMessage(message);
    }
  }

  void _handleForeground(RemoteMessage message) async {
    debugPrint('[FCM] fg data=${message.data}');
    final plugin = _plugin;
    if (plugin == null) {
      debugPrint('[FCM] fg skip — plugin null');
      return;
    }

    if (!await NearbyReportAlert.isGlobalNotificationsEnabled()) {
      debugPrint('[FCM] fg skip — global notifications off');
      return;
    }

    // TODO: 테스트 후 복구 — report 타입이 아니면 알림 생략
    // final isReport = ReportItem.isFcmReportPush(message.data) ||
    //     ReportItem.fromFcmData(message.data) != null;
    // if (!isReport) return;

    final report = ReportItem.fromFcmData(message.data);
    debugPrint(
      '[FCM] parsed report id=${report?.id} lat=${report?.lat} lng=${report?.lng}',
    );

    // 배너를 먼저 띄우고, 마커/목록은 이어서 처리
    await _ensureFcmAndroidChannel(plugin);
    await _showReportNotification(plugin, message, report);

    if (report != null) {
      await _onReportPush(message, report);
    } else {
      debugPrint('[FCM] report parse failed — marker skipped. data=${message.data}');
    }
  }

  void _handleTap(RemoteMessage message) async {
    final report = ReportItem.fromFcmData(message.data);
    if (report == null) return;
    await _onReportPush(message, report);
  }
}
