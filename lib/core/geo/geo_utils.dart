import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../config/env.dart';

/// 줌아웃 상한(= 허용 최소 zoom). 너무 멀어지면 격자·타일 과다.
const double kMapMinZoom = 13;

/// 줌인 상한
const double kMapMaxZoom = 18;

/// 지도·API 좌표 유효성 (finite + 범위). 실패 시 skip / 기본값.
bool isValidLatLng(double? lat, double? lng) {
  if (lat == null || lng == null) return false;
  if (!lat.isFinite || !lng.isFinite) return false;
  if (lat < -90 || lat > 90) return false;
  if (lng < -180 || lng > 180) return false;
  return true;
}

/// 하버사인 거리(km). 웹 distKm 과 동일 용도.
double distKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return r * c;
}

double _rad(double deg) => deg * math.pi / 180;

/// zoom NaN/0/범위 밖 → fallback (flutter_map tile floor 크래시 방지)
double safeZoom(double? zoom, {double fallback = 14}) {
  final fb = fallback.clamp(kMapMinZoom, kMapMaxZoom);
  if (zoom == null || !zoom.isFinite) return fb;
  if (zoom < 1 || zoom > 22) return fb;
  return zoom.clamp(kMapMinZoom, kMapMaxZoom);
}

LatLng defaultMapCenter() => const LatLng(Env.defaultLat, Env.defaultLng);

/// 유효하지 않으면 null (호출 측에서 skip)
LatLng? tryLatLng(double? lat, double? lng) {
  if (!isValidLatLng(lat, lng)) return null;
  return LatLng(lat!, lng!);
}

/// 유효하지 않으면 기본 중심
LatLng coerceLatLng(double? lat, double? lng, [LatLng? fallback]) {
  return tryLatLng(lat, lng) ?? fallback ?? defaultMapCenter();
}
