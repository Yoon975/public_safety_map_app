import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import '../core/theme/app_theme.dart';

/// 기기 OS 알림 권한 확인. OFF면 요청 후, 여전히 꺼져 있으면 설정 안내 다이얼로그.
///
/// 반환: 시스템 알림이 허용된 상태이면 true.
Future<bool> ensureDeviceNotificationPermission(BuildContext context) async {
  if (kIsWeb) return true;
  if (!Platform.isAndroid && !Platform.isIOS) return true;

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_report_warning'),
      iOS: DarwinInitializationSettings(),
    ),
  );

  var enabled = true;

  if (Platform.isAndroid) {
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    enabled = await android?.areNotificationsEnabled() ?? true;
    if (!enabled) {
      await android?.requestNotificationsPermission();
      enabled = await android?.areNotificationsEnabled() ?? false;
    }
  } else if (Platform.isIOS) {
    final ios = plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final result = await ios?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
    enabled = result ?? true;
  }

  if (!enabled && context.mounted) {
    await _showNotificationPermissionDialog(context);
  }
  return enabled;
}

Future<void> _showNotificationPermissionDialog(BuildContext context) async {
  final goSettings = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        '알림 권한이 꺼져 있습니다',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Color(0xFF0F172A),
        ),
      ),
      content: const Text(
        '앱에서 알림을 받으려면 휴대폰 설정에서 '
        '이 앱의 알림 권한을 허용해 주세요.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 15,
          height: 1.4,
          color: Color(0xFF64748B),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text(
            '나중에',
            style: TextStyle(color: Color(0xFF64748B)),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: MapUiColors.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('설정으로 이동'),
        ),
      ],
    ),
  );

  if (goSettings == true) {
    await Geolocator.openAppSettings();
  }
}
