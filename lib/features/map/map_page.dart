import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/config/env.dart';
import '../../core/config/media_url.dart';
import '../../core/format/event_text.dart';
import '../../core/geo/geo_utils.dart';
import '../../core/geo/region_code.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/user_error.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/map_provider.dart';
import '../../services/nearby_monitor.dart';
import '../../services/nearby_report_alert.dart';
import '../../services/guidance_notification.dart';
import '../../services/device_notification_permission.dart';
import '../../widgets/infra_cluster.dart';
import '../../widgets/media_image.dart';
import '../../widgets/report_markers.dart';

//nav
import '../../providers/nav_provider.dart';
import '../nav/nav_route_layer.dart';
import '../nav/nav_sheet.dart';
import 'long_press_map_menu.dart';

/// 기본 맵 줌
const double _defaultMapZoom = 17;
/// 내 위치 마커 줌
const double _myLocationZoom = 17;

/// 하단 패널 탭 (웹 좌측 레일: 격자 / 행사 / 제보 / 길찾기)
enum MapPanelTab { grid, event, report, nav }

String _accidentChipLabel(MapProvider map) {
  if (!map.accidentZonesVisible) return '위험구간';
  final n = map.visibleAccidentTypes.length;
  if (n == kAccidentZoneTypes.length) return '위험구간';
  if (n == 0) return '위험구간 · 없음';
  if (n == 1) {
    final t = map.visibleAccidentTypes.first;
    return '위험구간 · ${kAccidentZoneLabel[t] ?? t}';
  }
  return '위험구간 · $n종';
}

/// 마이페이지 내 제보와 동일한 날짜 표시 (YYYY-MM-DD HH:mm)
String? _formatListDateTime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final t = iso.replaceFirst('T', ' ');
  return t.length >= 16 ? t.substring(0, 16) : t;
}

class MapPage extends StatefulWidget {
  const MapPage({super.key, this.focus});

  /// 마이페이지 등에서 전달 (제보/격자 위치)
  final MapFocusTarget? focus;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  MapController _mapController = MapController();
  final _searchCtrl = TextEditingController();
  bool _booted = false;
  /// 권위 있는 카메라 이동(_loadAround)마다 증가 — 뒤늦게 도착한 GPS 응답이
  /// 그 사이 일어난 다른 이동(포커스 등)을 덮어쓰지 않도록 막는 세대 토큰.
  int _cameraOpGen = 0;
  bool _searching = false;
  /// 롱프레스로 고른 도착 좌표 (길찾기 시 Nominatim 재검색 생략)
  LatLng? _pinnedNavDest;
  /// 핀과 함께 넣은 검색창 문구 — 사용자가 수정하면 핀 무효
  String? _pinnedNavAddress;
  /// 롱프레스 메뉴로 고른 출발 (있으면 GPS 대신 사용)
  LatLng? _pinnedNavOrigin;
  /// 롱프레스 액션 메뉴
  LatLng? _longPressPoint;
  String? _longPressAddress;
  bool _longPressAddressLoading = false;
  /// FlutterMap 재마운트용 (카메라 NaN 복구)
  int _mapGeneration = 0;
  bool _remountingMap = false;
  /// layout 준비 전 deferred move
  (LatLng, double, Offset)? _pendingMove;
  /// pan/zoom 종료 후 격자·제보·행사 재조회 debounce
  Timer? _viewportDebounce;
  static const _viewportDebounceMs = 700;

  /// 논리적 최신 GPS (제보·알림·로드 기준)
  LatLng? _myPos;
  /// 마커용 보간 위치
  LatLng? _displayPos;
  /// 표시용 heading (라디안, 북쪽 0 · 시계방향)
  double _headingRad = 0;
  late final AnimationController _gpsAnim;
  LatLng? _gpsAnimFrom;
  LatLng? _gpsAnimTo;
  double _headingAnimFrom = 0;
  double _headingAnimTo = 0;
  static const _gpsAnimDuration = Duration(milliseconds: 320);
  /// 내 위치 마커 전용 리페인트 (MapPage setState 없이)
  final ValueNotifier<_MyLocPaint> _myLocPaint =
      ValueNotifier(const _MyLocPaint());
  StreamSubscription<Position>? _posSub;
  /// 알림 탭 → 해당 제보 열기
  StreamSubscription<int>? _openReportSub;
  StreamSubscription<AccidentZoneItem>? _openAccidentSub;

  /// 보간 위치를 카메라가 따라감 (북-up). 사용자 제스처 시 off → idle 후 재개.
  bool _followMe = true;
  Timer? _idleFollowTimer;
  // 정지 후 15초 뒤에 follow 중지
  static const _idleFollowDuration = Duration(seconds: 15);
  /// follow 중 MapProvider.setCenter 스로틀 (매 프레임 notify 방지)
  DateTime? _lastFollowProviderSync;
  static const _followProviderSyncInterval = Duration(seconds: 1);
  /// 내 위치 등에서 지정한 follow 줌. null 이면 카메라 현재 줌 유지.
  double? _followZoomOverride;
  /// follow 중 뷰포트(격자·인프라) 재조회: 마지막 로드 위치
  LatLng? _lastFollowLoadPos;
  /// follow 중 이 거리(m) 이상 이동 시 1회 로드
  static const double _followLoadMinMeters = 230;
  /// 프로그램 이동으로 인한 map 이벤트를 사용자 제스처로 오인 방지
  bool _programmaticCamera = false;
  GoRouter? _router;
  VoidCallback? _routeListener;

  MapPanelTab _panelTab = MapPanelTab.grid;
  /// 하단 패널 높이(px). null 이면 접힘(헤더만).
  double? _panelHeightPx;
  /// 드래그 중이면 높이 애니 끄기
  bool _panelDragging = false;

  /// 접힘 높이 추정값 (드래그 스냅·FAB 위치용). 실제 헤더는 intrinsic.
  static const double _collapsedBarH = 56;
  static const double _expandedFracBase = 0.30;

  int? _selectedReportId;
  int? _selectedEventId;
  bool _nearbyMenu = false;
  bool _gridMenu = false;
  bool _accidentMenu = false;

  DateTime? _lastBackPress;

  void _closeFilterMenus() {
    if (!_nearbyMenu && !_gridMenu && !_accidentMenu) return;
    setState(() {
      _nearbyMenu = false;
      _gridMenu = false;
      _accidentMenu = false;
    });
  }

  /// 경로 fit 전 카메라 — 길찾기 종료 시 복원
  (LatLng, double)? _preRouteCamera;
  bool _navWasActive = false;
  bool _wasGuiding = false;
  bool _wasArrived = false;
  NavProvider? _navListened;
  MapProvider? _mapListened;

  @override
  void initState() {
    super.initState();
    _gpsAnim = AnimationController(
      vsync: this,
      duration: _gpsAnimDuration,
    )..addListener(_onGpsAnimTick);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (router != null && !identical(router, _router)) {
      if (_router != null && _routeListener != null) {
        _router!.routerDelegate.removeListener(_routeListener!);
      }
      _router = router;
      _routeListener = _onRouteChanged;
      router.routerDelegate.addListener(_routeListener!);
    }
    final nav = context.read<NavProvider>();
    if (!identical(_navListened, nav)) {
      _navListened?.removeListener(_onNavProviderChanged);
      _navListened = nav;
      _navWasActive = nav.active;
      _wasGuiding = nav.guiding;
      _wasArrived = nav.arrived;
      nav.addListener(_onNavProviderChanged);
    }
    final map = context.read<MapProvider>();
    if (!identical(_mapListened, map)) {
      _mapListened?.removeListener(_onMapProviderChanged);
      _mapListened = map;
      map.addListener(_onMapProviderChanged);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) {
        unawaited(context.read<MapProvider>().hydratePendingFcmReports());
      }
      _onMapScreenVisibilityMaybeResumed();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _idleFollowTimer?.cancel();
    }
  }

  /// 포커스가 대기 중인데 라우트 전환이 아직 안 끝나서 `_isMapRouteActive`가
  /// false로 나오는 경우 재시도하는 횟수 — go_router의 routerDelegate 리스너는
  /// go() 호출 시점에 한 번만 알려주고, 실제 라우트 전환이 끝난 뒤에는 다시
  /// 알려주지 않아서 다음 프레임에 직접 재확인해야 한다(안 하면 MapProvider의
  /// 5초 안전장치 타임아웃이 만료될 때까지 포커스 이동이 멈춰 있었음).
  int _focusRecheckAttempts = 0;

  void _onRouteChanged() {
    if (!mounted) return;
    if (_isMapRouteActive) {
      _focusRecheckAttempts = 0;
      final map = context.read<MapProvider>();
      final focusing = map.pendingFocus != null || map.mapFocusing;
      if (focusing) {
        // 마이페이지 포커스: GPS follow 복귀 건너뛰고 바로 목적지로
        _disableFollowForFocus();
        unawaited(_consumePendingFocus());
      } else {
        _onMapScreenVisibilityMaybeResumed();
      }
    } else {
      // 다른 화면: idle 정지 (6-A)
      _idleFollowTimer?.cancel();

      final map = context.read<MapProvider>();
      if ((map.pendingFocus != null || map.mapFocusing) &&
          _focusRecheckAttempts < 20) {
        _focusRecheckAttempts++;
        WidgetsBinding.instance.addPostFrameCallback((_) => _onRouteChanged());
      }
    }
  }

  void _onMapProviderChanged() {
    if (!mounted) return;
    final map = _mapListened;
    if (map == null) return;

    // 포커스 예약 즉시 follow OFF (화면 복귀 전 GPS 당김 방지)
    if ((map.mapFocusing || map.pendingFocus != null) && _followMe) {
      _disableFollowForFocus();
    }

    if (!_booted || !_isMapRouteActive) return;
    if (map.pendingFocus == null) return;
    unawaited(_consumePendingFocus());
  }

  Future<void> _consumePendingFocus() async {
    if (!mounted || !_booted) return;
    final focus = context.read<MapProvider>().takePendingFocus();
    if (focus == null) return;
    await _applyMapFocus(focus);
  }

  /// 포커스 이동용: follow OFF + idle 타이머도 걸지 않음
  void _disableFollowForFocus() {
    _followZoomOverride = null;
    _idleFollowTimer?.cancel();
    if (!_followMe) return;
    if (mounted) {
      setState(() => _followMe = false);
    } else {
      _followMe = false;
    }
  }

  void _onMapScreenVisibilityMaybeResumed() {
    if (!mounted || !_isMapRouteActive) return;
    // 포커스 이동 중에는 내 위치로 카메라를 당기지 않음
    if (_mapListened?.mapFocusing == true ||
        _mapListened?.pendingFocus != null) {
      return;
    }
    if (_followMe) {
      _syncFollowCamera();
    } else {
      _armIdleFollowTimer();
    }
  }

  /// /map 이고 스택 최상단일 때만 active
  bool get _isMapRouteActive {
    try {
      final path = GoRouter.of(context).state.uri.path;
      if (path != '/map') return false;
    } catch (_) {}
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    return true;
  }

  void _publishMyLocPaint() {
    final p = _displayPos ?? _myPos;
    _myLocPaint.value = _MyLocPaint(pos: p, headingRad: _headingRad);
  }

  void _onGpsAnimTick() {
    final from = _gpsAnimFrom;
    final to = _gpsAnimTo;
    if (from == null || to == null) return;
    final t = Curves.easeOut.transform(_gpsAnim.value);
    _displayPos = LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );
    _headingRad = _lerpHeadingRad(_headingAnimFrom, _headingAnimTo, t);
    _publishMyLocPaint();
    if (_followMe) _syncFollowCamera();
  }

  /// 최초 위치·강제 스냅 (보간 없이 즉시).
  void _snapMyLocation(LatLng p, {double? headingRad}) {
    _gpsAnim.stop();
    _gpsAnimFrom = null;
    _gpsAnimTo = null;
    _myPos = p;
    _displayPos = p;
    if (headingRad != null) _headingRad = headingRad;
    _publishMyLocPaint();
    if (_followMe) _syncFollowCamera();
  }

  /// GPS 목표로 표시 위치를 미끄러지듯 이동 (easeOut 보간).
  void _animateMyLocationTo(LatLng p, {double? headingRad}) {
    _myPos = p;
    final headingTo = headingRad ?? _headingRad;

    // 첫 좌표는 바로 찍기
    if (_displayPos == null) {
      _displayPos = p;
      _headingRad = headingTo;
      _publishMyLocPaint();
      if (_followMe) _syncFollowCamera();
      return;
    }

    _gpsAnimFrom = _displayPos;
    _gpsAnimTo = p;
    _headingAnimFrom = _headingRad;
    _headingAnimTo = headingTo;
    _gpsAnim
      ..stop()
      ..forward(from: 0);
  }

  double _lerpHeadingRad(double from, double to, double t) {
    var d = to - from;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    return from + d * t;
  }

  /// GPS 스트림 fix → 논리 즉시 + 표시 보간.
  void _applyGpsFix(Position pos) {
    final p = tryLatLng(pos.latitude, pos.longitude);
    if (p == null || !mounted) return;
    final nextHeading = _resolveHeadingRad(pos, p);
    _animateMyLocationTo(p, headingRad: nextHeading);
    final nav = context.read<NavProvider>();
    if (nav.guiding) {
      nav.updateGuideProgress(p);
      unawaited(_syncGuidanceNotification(nav));
    }
  }

  /// 사용자 맵 제스처 → 따라가기 OFF + idle (1-A)
  void _onMapUserGesture() {
    _followZoomOverride = null;
    if (!_followMe) {
      _onUserActivity();
      return;
    }
    if (mounted) {
      setState(() => _followMe = false);
    } else {
      _followMe = false;
    }
    _armIdleFollowTimer();
  }

  /// 맵 외 UI 조작: 따라가기는 유지, idle만 리셋 (follow off일 때 20초 연장) (4-C)
  void _onUserActivity() {
    if (_followMe) return;
    _armIdleFollowTimer();
  }

  void _armIdleFollowTimer() {
    _idleFollowTimer?.cancel();
    if (!mounted || _followMe || !_isMapRouteActive) return;
    // 안내 중이 아니면 자동 복귀 안 함
    final guiding = context.read<NavProvider>().guiding;
    if (!guiding) return;
    _idleFollowTimer = Timer(_idleFollowDuration, _onIdleFollowTimeout);
  }

  void _onIdleFollowTimeout() {
    if (!mounted || _followMe) return;
    if (!context.read<NavProvider>().guiding) return;  // 안내종료후 남은 타이머 요청 종료
    if (!_isMapRouteActive) {
      // 화면 복귀 시 다시 arm
      return;
    }
    setState(() => _followMe = true);
    _idleFollowTimer?.cancel();
    final p = _displayPos ?? _myPos;
    if (p != null) {
      double z = 15;
      try {
        z = safeZoom(_mapController.camera.zoom);
      } catch (_) {}
      _safeMapMove(p, z);
    } else {
      _syncFollowCamera();
    }
  }

  void _enableFollowAndCenter({double? zoom}) {
    _idleFollowTimer?.cancel();
    if (mounted) {
      setState(() => _followMe = true);
    } else {
      _followMe = true;
    }
    final p = _displayPos ?? _myPos;
    if (p == null) return;

    double z;
    if (zoom != null) {
      z = safeZoom(zoom);
      _followZoomOverride = z; // follow 중 줌 유지
    } else {
      try {
        z = safeZoom(_followZoomOverride ?? _mapController.camera.zoom);
      } catch (_) {
        z = safeZoom(_followZoomOverride ?? _defaultMapZoom);
      }
    }
    _safeMapMove(p, z);
  }

    void _syncFollowCamera() {
    if (!_followMe || !mounted || !_isMapRouteActive) return;
    if (_mapListened?.mapFocusing == true) return;
    final raw = _displayPos ?? _myPos;
    if (raw == null) return;
    final p = tryLatLng(raw.latitude, raw.longitude);
    if (p == null) return;
    double z;
    try {
      z = safeZoom(
        _followZoomOverride ?? _mapController.camera.zoom,
      );
    } catch (_) {
      z = safeZoom(_followZoomOverride ?? _defaultMapZoom);
    }
    if (!_cameraHealthy() || !_mapLayoutReady()) return;

    _programmaticCamera = true; //GPS follow 이동 ≠ 사용자 제스처
    try {
      // 카메라는 매 프레임 추적 (가벼운 move)
      _mapController.move(p, z);
      if (!mounted) return;
      final mp = context.read<MapProvider>();
      // setZoom 은 notify 없음 → 매 프레임 가능
      mp.setZoom(z);
      // setCenter 는 notifyListeners → 1초에 한 번만 (전체 rebuild 억제)
      final now = DateTime.now();
      final last = _lastFollowProviderSync;
      if (last == null ||
          now.difference(last) >= _followProviderSyncInterval) {
        _lastFollowProviderSync = now;
        mp.setCenter(p);
        // _maybeLoadAroundWhileFollowing(p, z); // follow 중 이 거리(m) 이상 이동 시 1회 로드
      }
    } catch (_) {
      // ignore — remount 경로에 맡김
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _programmaticCamera = false;
      });
    }
  }

  static bool _isUserMapGestureSource(MapEventSource source) {
    switch (source) {
      case MapEventSource.dragStart:
      case MapEventSource.onDrag:
      case MapEventSource.dragEnd:
      case MapEventSource.multiFingerGestureStart:
      case MapEventSource.onMultiFinger:
      case MapEventSource.multiFingerEnd:
      case MapEventSource.scrollWheel:
      case MapEventSource.doubleTap:
      case MapEventSource.doubleTapHold:
      case MapEventSource.doubleTapZoomAnimationController:
      case MapEventSource.flingAnimationController:
      case MapEventSource.cursorKeyboardRotation:
      case MapEventSource.keyboard:
        return true;
      case MapEventSource.mapController:
      case MapEventSource.tap:
      case MapEventSource.secondaryTap:
      case MapEventSource.longPress:
      case MapEventSource.interactiveFlagsChanged:
      case MapEventSource.fitCamera:
      case MapEventSource.custom:
      case MapEventSource.nonRotatedSizeChange:
        return false;
    }
  }

  double _resolveHeadingRad(Position pos, LatLng p) {
    final speed = pos.speed; // m/s
    final h = pos.heading;
    if (h.isFinite && h >= 0 && h <= 360) {
      final acc = pos.headingAccuracy;
      // < 0 또는 non-finite = 미제공으로 간주하고 허용
      final accOk = !acc.isFinite || acc < 0 || acc <= 50;
      if (accOk && speed.isFinite && speed >= 0.4) {
        return h * math.pi / 180;
      }
    }
    // 이동 벡터로 추정
    final from = _displayPos ?? _myPos;
    if (from != null) {
      final meters = Geolocator.distanceBetween(
        from.latitude,
        from.longitude,
        p.latitude,
        p.longitude,
      );
      if (meters >= 1.2) {
        final bearing = Geolocator.bearingBetween(
          from.latitude,
          from.longitude,
          p.latitude,
          p.longitude,
        );
        return bearing * math.pi / 180;
      }
    }
    return _headingRad;
  }

  LocationSettings _mapGpsSettings({bool forGuidance = false}) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      if (forGuidance) {
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3,
          intervalDuration: const Duration(milliseconds: 500),
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: '보행 안내 중',
            notificationText: '목적지로 길안내를 진행합니다',
            notificationChannelName: '보행 안내',
            enableWakeLock: true,
            setOngoing: true,
          ),
        );
      }
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
        intervalDuration: const Duration(milliseconds: 500),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
        activityType: ActivityType.otherNavigation,
        pauseLocationUpdatesAutomatically: !forGuidance,
        allowBackgroundLocationUpdates: forGuidance,
        showBackgroundLocationIndicator: forGuidance,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );
  }

  Future<void> _boot() async {
    final map = context.read<MapProvider>();
    try {
      final focus = widget.focus ?? map.takePendingFocus();
      final focusPoint =
          focus != null ? tryLatLng(focus.lat, focus.lng) : null;

      // 마이페이지 등에서 특정 위치로 올 때 GPS 따라가기가 카메라를 가로채지 않게
      if (focus != null) {
        _disableFollowForFocus();
      }

      await _initialLoad(
        cameraCenter: focusPoint,
        cameraZoom: focusPoint != null ? 16.0 : null,
      );
      if (!mounted) return;

      final alert = context.read<NearbyReportAlert>();
      _openReportSub = alert.openReportStream.listen((id) {
        if (!mounted) return;
        alert.takePendingOpenReportId();
        unawaited(_openReportById(id));
      });
      _openAccidentSub = alert.openAccidentStream.listen((z) {
        if (!mounted) return;
        alert.takePendingOpenAccident();
        unawaited(_openAccidentZone(z));
      });

      final pending = alert.takePendingOpenReportId();
      if (pending != null) {
        await _openReportById(pending);
      }
      final pendingAcc = alert.takePendingOpenAccident();
      if (pendingAcc != null) {
        await _openAccidentZone(pendingAcc);
      }

      if (focus != null) {
        await _applyMapFocus(focus, alreadyLoadedAt: focusPoint);
      }

      // go('/map')로 복귀했는데 _boot가 이미 끝난 인스턴스면 위에서 소비.
      await _consumePendingFocus();
    } finally {
      map.clearMapFocusing();
    }
  }

  /// 마이페이지·알림 외 경로에서 전달된 지도 포커스 적용
  Future<void> _applyMapFocus(
    MapFocusTarget focus, {
    LatLng? alreadyLoadedAt,
  }) async {
    void clearFocusing() {
      (_mapListened ??
              (mounted ? context.read<MapProvider>() : null))
          ?.clearMapFocusing();
    }

    if (!mounted) {
      clearFocusing();
      return;
    }
    try {
      _disableFollowForFocus();

      final alert = context.read<NearbyReportAlert>();
      final p = tryLatLng(focus.lat, focus.lng);
      final reportId = focus.reportId;

      // 캐시에 제보가 있어도 viewport 마커는 map.reports에서 그리므로
      // 이동 후 항상 _loadAround 한다. (이미 동일 좌표로 initialLoad 한 경우만 생략)
      if (p != null) {
        _focusMapOn(p, zoom: 16);
        final same = alreadyLoadedAt != null &&
            (alreadyLoadedAt.latitude - p.latitude).abs() < 1e-9 &&
            (alreadyLoadedAt.longitude - p.longitude).abs() < 1e-9;
        if (!same) {
          await _loadAround(p, 16);
        }
        if (!mounted) return;

        if (reportId != null) {
          ReportItem? after;
          for (final item in context.read<MapProvider>().reports) {
            if (item.id == reportId) {
              after = item;
              break;
            }
          }
          after ??= alert.cachedReport(reportId);
          if (after != null) {
            _selectReport(after, moveMap: false);
          }
        }
      }

      final gridId = focus.gridId;
      if (gridId != null && mounted) {
        await _onGridTap(gridId);
        if (!mounted) return;
        final detail = context.read<MapProvider>().selectedGridDetail;
        final gp = tryLatLng(detail?.lat, detail?.lng);
        if (gp != null) {
          _disableFollowForFocus();
          _focusMapOn(gp, zoom: 16);
          // await _loadAround(gp, 16);
        }
      }
    } finally {
      clearFocusing();
    }
  }

  /// 알림에서 선택한 제보를 지도에서 열고 선택 상태 표시
  Future<void> _openReportById(int reportId) async {
    if (!mounted) return;
    _onMapUserGesture();

    final alert = context.read<NearbyReportAlert>();
    final map = context.read<MapProvider>();

    ReportItem? findLocal() {
      for (final r in map.reports) {
        if (r.id == reportId) return r;
      }
      return alert.cachedReport(reportId);
    }

    var r = findLocal();
    final focus = tryLatLng(r?.lat, r?.lng);
    if (focus != null) {
      _safeMapMove(focus, 16);
      await _loadAround(focus, 16);
      if (!mounted) return;
      r = findLocal() ?? r;
    } else if (_myPos != null) {
      await _loadAround(_myPos!, 16);
      if (!mounted) return;
      r = findLocal() ?? r;
    }

    if (!mounted) return;
    if (r == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('해당 제보를 찾을 수 없습니다')),
      );
      return;
    }
    _selectReport(r, moveMap: true);
  }

  /// 위험구간 알림 탭 → 지도 이동 + 위험구간 표시
  Future<void> _openAccidentZone(AccidentZoneItem z) async {
    if (!mounted) return;
    _onMapUserGesture();
    final map = context.read<MapProvider>();
    if (!map.accidentZonesVisible) {
      map.toggleAccidentZones();
    }

    LatLng? focus = tryLatLng(z.lat, z.lng);
    if (focus == null) {
      for (final p in z.path) {
        focus = tryLatLng(p.lat, p.lng);
        if (focus != null) break;
      }
    }
    if (focus != null) {
      _safeMapMove(focus, 16);
      await _loadAround(focus, 16);
    }
  }

  @override
  void dispose() {
    if (_router != null && _routeListener != null) {
      _router!.routerDelegate.removeListener(_routeListener!);
    }
    WidgetsBinding.instance.removeObserver(this);
    _viewportDebounce?.cancel();
    _idleFollowTimer?.cancel();
    _navListened?.removeListener(_onNavProviderChanged);
    _navListened = null;
    _mapListened?.removeListener(_onMapProviderChanged);
    _mapListened = null;
    _openReportSub?.cancel();
    _openAccidentSub?.cancel();
    _posSub?.cancel();
    _gpsAnim.dispose();
    _myLocPaint.dispose();
    _searchCtrl.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _onNavProviderChanged() {
    if (!mounted) return;
    final nav = _navListened;
    if (nav == null) return;
    if (_navWasActive && !nav.active) {
    _restorePreRouteCamera();
    _dismissLongPressMenu();
    }
    if (nav.origin == null) {
      _pinnedNavOrigin = null;
    }
    _navWasActive = nav.active;

    unawaited(_syncGuidanceNotification(nav));

    if (!_wasArrived && nav.arrived && nav.guiding) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('목적지 주변입니다. 알림에서 안내를 종료할 수 있습니다'),
        ),
      );
    }
    _wasArrived = nav.arrived;

    if (_wasGuiding && !nav.guiding) {
      unawaited(_restartLocationTracking(forGuidance: false));
    }
    _wasGuiding = nav.guiding;
  }

  Future<void> _syncGuidanceNotification(NavProvider nav) async {
    try {
      final g = context.read<GuidanceNotification>();
      await g.syncFromNav(nav);
    } catch (_) {}
  }

  void _capturePreRouteCameraIfNeeded() {
    if (_preRouteCamera != null) return;
    try {
      final cam = _mapController.camera;
      final c = tryLatLng(cam.center.latitude, cam.center.longitude);
      if (c == null) return;
      _preRouteCamera = (c, safeZoom(cam.zoom));
    } catch (_) {}
  }

  void _fitSelectedRoute() {
    final nav = context.read<NavProvider>();
    if (!nav.active || nav.guiding) return;
    final pts = nav.selected?.points;
    if (pts == null || pts.length < 2) return;

    _capturePreRouteCameraIfNeeded();
    _onMapUserGesture();

    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final sheetH = nav.sheetHeight > 0 ? nav.sheetHeight : 72;
    // 상단 검색·칩 + 하단 접힌 경로시트·격자 헤더 여유
    final pad = EdgeInsets.fromLTRB(
      48,
      140,
      48,
      (sheetH + 56 + bottomPad + 24).clamp(160.0, 360.0),
    );

    if (!_mapLayoutReady() || !_cameraHealthy()) {
      final mid = pts[pts.length ~/ 2];
      _safeMapMove(mid, 15);
      return;
    }

    _programmaticCamera = true;
    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: pad,
          maxZoom: 17,
        ),
      );
    } catch (_) {
      final mid = pts[pts.length ~/ 2];
      _safeMapMove(mid, 15);
    } finally {
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (mounted) _programmaticCamera = false;
      });
    }
  }

  void _restorePreRouteCamera() {
    final saved = _preRouteCamera;
    _preRouteCamera = null;
    if (saved == null || !mounted) return;
    _safeMapMove(saved.$1, saved.$2);
  }

  /// 위험구간 ON/OFF. 알림 검사는 NearbyMonitor(ON) 경로만 사용.
  void _toggleAccidentZonesUi() {
    context.read<MapProvider>().toggleAccidentZones();
  }

  Future<void> _toggleNearbyMonitor() async {
    final monitor = context.read<NearbyMonitor>();
    final wasOn = monitor.enabled;
    if (!wasOn) {
      final ok = await ensureDeviceNotificationPermission(context);
      if (!mounted) return;
      if (!ok) return; // 시스템 알림 권한 없으면 ON 유지하지 않음
    }
    final err = await monitor.toggle();
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          wasOn
              ? '주변 제보 감시를 껐습니다'
              : '주변 제보 감시 ON · 백그라운드에서도 400m 안 제보를 알립니다',
        ),
      ),
    );
  }

  /// 지도 위젯 실측 크기 (0/NaN/미레이아웃이면 false)
  bool _mapLayoutReady() {
    try {
      final s = _mapController.camera.nonRotatedSize;
      return s.width.isFinite &&
          s.height.isFinite &&
          s.width > 2 &&
          s.height > 2;
    } catch (_) {
      return false;
    }
  }

  /// 카메라 center/zoom/size 가 타일 계산에 안전한지
  bool _cameraHealthy() {
    try {
      final cam = _mapController.camera;
      if (!isValidLatLng(cam.center.latitude, cam.center.longitude)) {
        return false;
      }
      if (!cam.zoom.isFinite) return false;
      final s = cam.nonRotatedSize;
      if (!s.width.isFinite || !s.height.isFinite) return false;
      if (s.width <= 2 || s.height <= 2) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 깨진 카메라 → MapController + FlutterMap 재생성
  void _remountMap({LatLng? preferCenter, double? preferZoom}) {
    if (!mounted || _remountingMap) return;
    _remountingMap = true;

    final mp = context.read<MapProvider>();
    final center = tryLatLng(
          preferCenter?.latitude,
          preferCenter?.longitude,
        ) ??
        coerceLatLng(mp.center.latitude, mp.center.longitude);
    final zoom = safeZoom(preferZoom ?? mp.zoom);

    final old = _mapController;
    setState(() {
      _mapGeneration++;
      _mapController = MapController();
      _pendingMove = null;
    });
    mp.setCenter(center);
    mp.setZoom(zoom);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        old.dispose();
      } catch (_) {}
      if (!mounted) return;
      _remountingMap = false;
      // 레이아웃 잡힌 뒤 중심 고정
      _safeMapMove(center, zoom);
    });
  }

  void _ensureCameraHealthyOrRemount(MapCamera cam) {
    final centerOk =
        isValidLatLng(cam.center.latitude, cam.center.longitude);
    final zoomOk = cam.zoom.isFinite;
    final size = cam.nonRotatedSize;
    final sizeOk = size.width.isFinite &&
        size.height.isFinite &&
        size.width > 2 &&
        size.height > 2;
    if (centerOk && zoomOk && sizeOk) return;

    // size만 아직 0인 초기 프레임은 remount 대신 대기
    if (centerOk && zoomOk && !sizeOk) return;

    _remountMap(
      preferCenter: centerOk
          ? LatLng(cam.center.latitude, cam.center.longitude)
          : null,
      preferZoom: zoomOk ? cam.zoom : null,
    );
  }

  Future<void> _initialLoad({
    LatLng? cameraCenter,
    double? cameraZoom,
  }) async {
    if (_booted) return;
    _booted = true;

    // 기본값: 마지막으로 보던 위치(MapProvider.hydrateLastPosition, 없으면 서울)
    // cameraCenter가 있으면(마이페이지 포커스) 카메라는 그쪽으로.
    // GPS는 어느 쪽이든 기다리지 않고 바로 데이터를 그린 뒤 백그라운드에서 보정한다.
    final c = cameraCenter ??
        coerceLatLng(
          context.read<MapProvider>().center.latitude,
          context.read<MapProvider>().center.longitude,
        );
    final z = cameraZoom ?? (cameraCenter != null ? 16.0 : 14.0);

    if (!mounted) return;
    context.read<MapProvider>().setCenter(c);
    context.read<MapProvider>().setZoom(z);
    _safeMapMove(c, z);
    await _loadAround(c, z);

    if (cameraCenter != null) {
      // 포커스 이동: 내 위치 마커만 백그라운드로 (카메라는 건드리지 않음)
      unawaited(_tryStartLocationTracking(requestPermission: false));
    } else {
      // 일반 진입: GPS로 실제 위치를 백그라운드에서 확인 후 도착하면 보정
      unawaited(_resolveInitialGpsFix());
    }
  }

  /// `_initialLoad`가 이미 마지막 위치(또는 기본값)로 화면을 띄운 뒤,
  /// GPS로 실제 현재 위치를 확인해 오면 그때 카메라를 보정한다.
  /// 그 사이 다른 카메라 이동(포커스 등)이 있었으면 `_cameraOpGen`이 달라져 조용히 무시된다.
  Future<void> _resolveInitialGpsFix() async {
    final myGen = _cameraOpGen;
    final hasLocation = await _ensureLocationPermission(request: true);
    if (!hasLocation || !mounted) return;

    Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (_) {
      // 타임아웃·실패 — 이미 화면엔 마지막/기본 위치가 떠 있으므로 조용히 포기
      return;
    }

    final p = tryLatLng(pos.latitude, pos.longitude);
    if (p == null || !mounted) return;
    if (myGen != _cameraOpGen) return; // 그 사이 다른 카메라 이동 발생 — GPS 결과 폐기

    _snapMyLocation(p, headingRad: _resolveHeadingRad(pos, p));
    _safeMapMove(p, _myLocationZoom);
    await _loadAround(p, _myLocationZoom);
    if (!mounted) return;
    // 이후 위치 스트림(파란 점 갱신)만 이어받음 — 첫 fix는 이미 위에서 처리했으므로 중복 없음
    unawaited(_tryStartLocationTracking(requestPermission: false));
  }

  Future<void> _loadAround(LatLng center, double zoom) async {
    _cameraOpGen++;
    final safeCenter = tryLatLng(center.latitude, center.longitude);
    if (safeCenter == null) return;

    final z = safeZoom(zoom);
    final ratio = (z / 12).clamp(0.5, 2.5);
    final delta = 0.04 / ratio;
    if (!delta.isFinite || delta <= 0) return;

    final swLat = safeCenter.latitude - delta;
    final swLng = safeCenter.longitude - delta;
    final neLat = safeCenter.latitude + delta;
    final neLng = safeCenter.longitude + delta;
    if (![swLat, swLng, neLat, neLng].every((v) => v.isFinite)) return;

    if (!mounted) return;
    context.read<MapProvider>().setZoom(z);
    await context.read<MapProvider>().refreshFromViewport(
          swLat: swLat,
          swLng: swLng,
          neLat: neLat,
          neLng: neLng,
          newCenter: safeCenter,
        );
  }

    /// follow ON일 때만: 마지막 로드 지점에서 [_followLoadMinMeters] 이상 이동 시 갱신
  void _maybeLoadAroundWhileFollowing(LatLng pos, double zoom) {
    if (!_followMe) return;
    final p = tryLatLng(pos.latitude, pos.longitude);
    if (p == null) return;

    final last = _lastFollowLoadPos;
    if (last != null) {
      final m = Geolocator.distanceBetween(
        last.latitude,
        last.longitude,
        p.latitude,
        p.longitude,
      );
      if (m < _followLoadMinMeters) return;
    }

    _lastFollowLoadPos = p;
    _scheduleLoadAround(p, zoom);
  }

  /// 제스처(MapEventMoveEnd) 전용 — 700ms 안 추가 이동이면 마지막 좌표만 조회
  void _scheduleLoadAround(LatLng center, double zoom) {
    _viewportDebounce?.cancel();
    final c = tryLatLng(center.latitude, center.longitude);
    if (c == null) return;
    final z = safeZoom(zoom);
    _viewportDebounce = Timer(
      const Duration(milliseconds: _viewportDebounceMs),
      () {
        if (!mounted) return;
        _loadAround(c, z);
      },
    );
  }

  Future<bool> _ensureLocationPermission({required bool request}) async {
    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      if (mounted && request) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('위치 서비스가 꺼져 있습니다')),
        );
      }
      return false;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied && request) {
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      if (mounted && request) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('위치 권한이 필요합니다')),
        );
      }
      return false;
    }
    return true;
  }

  /// GPS 스트림 — 마커를 위치에 따라 갱신
  Future<void> _tryStartLocationTracking({required bool requestPermission}) async {
    final forGuidance = context.read<NavProvider>().guiding;
    final ok = await _ensureLocationPermission(request: requestPermission);
    if (!ok || !mounted) return;
    if (_posSub != null) return;

    // 첫 위치 (이미 있으면 스킵)
    if (_myPos == null) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
        final p = tryLatLng(pos.latitude, pos.longitude);
        if (p != null && mounted) {
          _snapMyLocation(p, headingRad: _resolveHeadingRad(pos, p));
        }
      } catch (_) {}
    }

    if (!mounted) return;
    final settings = _mapGpsSettings(forGuidance: forGuidance);
    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _applyGpsFix,
      onError: (_) {},
    );
  }

  /// 안내 ON/OFF에 맞춰 GPS 스트림 재구독 (Android FGS 알림 포함)
  Future<void> _restartLocationTracking({required bool forGuidance}) async {
    final ok = await _ensureLocationPermission(request: true);
    if (!ok || !mounted) return;
    await _posSub?.cancel();
    _posSub = null;
    final settings = _mapGpsSettings(forGuidance: forGuidance);
    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _applyGpsFix,
      onError: (_) {},
    );
  }

  Future<void> _myLocation() async {
    _closeFilterMenus();
    await _tryStartLocationTracking(requestPermission: true);
    if (!mounted) return;
    final latLng = _displayPos ?? _myPos;
    if (latLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('위치를 가져오지 못했습니다')),
      );
      return;
    }
    // 내 위치로 돌아가면 롱프레스 출발 고정 해제
    _pinnedNavOrigin = null;
    // 5-B: 1회 센터 + 따라가기 ON
    _followZoomOverride = _myLocationZoom;
    _enableFollowAndCenter(zoom: _myLocationZoom);
    await _loadAround(latLng, _myLocationZoom);
    _lastFollowLoadPos = latLng;
  }

  /// 롱프레스로 넣은 주소·좌표가 그대로면 true (Nominatim 재검색 생략)
  bool _canUsePinnedSearchDest(String q) {
    final pinned = _pinnedNavDest;
    return pinned != null &&
        _pinnedNavAddress != null &&
        q == _pinnedNavAddress &&
        isValidLatLng(pinned.latitude, pinned.longitude);
  }

  Future<void> _runSearch() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    _closeFilterMenus();
    _onMapUserGesture(); // 검색 이동 = 탐색 (follow off)
    setState(() => _searching = true);

    LatLng? point;
    if (_canUsePinnedSearchDest(q)) {
      // 카카오 주소 → Nominatim 실패 방지: 꾹 누른 좌표로 이동
      point = _pinnedNavDest;
    } else {
      point = await context.read<MapProvider>().searchPlace(q);
    }

    if (!mounted) return;
    setState(() => _searching = false);
    if (point == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('검색 결과가 없습니다')),
      );
      return;
    }
    _safeMapMove(point, 17);
    await _loadAround(point, 17);
  }

  void _clearPinnedNavDest() {
    _pinnedNavDest = null;
    _pinnedNavAddress = null;
  }

  void _onSearchTextChanged(String _) {
    _onUserActivity();
    final t = _searchCtrl.text.trim();
    if (_pinnedNavAddress != null && t != _pinnedNavAddress) {
      _clearPinnedNavDest();
    }
  }

  void _dismissLongPressMenu() {
    if (_longPressPoint == null &&
        !_longPressAddressLoading &&
        _longPressAddress == null) {
      return;
    }
    setState(() {
      _longPressPoint = null;
      _longPressAddress = null;
      _longPressAddressLoading = false;
    });
  }

  /// 지도 롱프레스 → 출발/도착/주소 메뉴
  Future<void> _openLongPressMenu(LatLng latLng) async {
    if (!isValidLatLng(latLng.latitude, latLng.longitude)) return;
    _onUserActivity();
    _onMapUserGesture();

    setState(() {
      _longPressPoint = latLng;
      _longPressAddress = null;
      _longPressAddressLoading = true;
    });

    final address = await coordToAddress(
      lat: latLng.latitude,
      lng: latLng.longitude,
    );
    if (!mounted) return;
    // 다른 지점을 또 누른 경우 이전 요청 결과 무시
    if (_longPressPoint != latLng) return;

    setState(() {
      _longPressAddress = (address != null && address.isNotEmpty)
          ? address
          : null;
      _longPressAddressLoading = false;
    });
  }

  String _longPressLabel() {
    final a = _longPressAddress;
    if (a != null && a.isNotEmpty) return a;
    return '선택한 위치';
  }

  void _onLongPressSetOrigin() {
    final p = _longPressPoint;
    if (p == null) return;
    final nav = context.read<NavProvider>();
    if (nav.guiding || nav.arrived) {
      nav.cancelGuidanceForReplan();
    }
    _pinnedNavOrigin = p;
    if (!nav.active) {
      nav.toggleActive(myPos: p);
    } else {
      nav.setOrigin(p);
    }
    _dismissLongPressMenu();
    if (nav.destination != null) {
  unawaited(nav.plan().then((_) {
      if (mounted) _showNavPanel();
    }));
  } else {
    _showNavPanel(); // 출발만 정했을 때도 길찾기 탭 안내
}
  }

  Future<void> _onLongPressSetDestination() async {
    final p = _longPressPoint;
    if (p == null) return;
    final label = _longPressLabel();
    _pinnedNavDest = p;
    _pinnedNavAddress = label;
    _searchCtrl.text = label;
    _searchCtrl.selection = TextSelection.collapsed(offset: label.length);
    _dismissLongPressMenu();
    await _runNavSearch();
  }

  Future<void> _onLongPressCopyAddress() async {
    final a = _longPressAddress;
    final p = _longPressPoint;
    if (a == null || a.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: a));
    if (!mounted) return;
    if (p != null && isValidLatLng(p.latitude, p.longitude)) {
      _pinnedNavDest = p;
      _pinnedNavAddress = a;
    }
    _searchCtrl.text = a;
    _searchCtrl.selection = TextSelection.collapsed(offset: a.length);
    _dismissLongPressMenu();
  }

  /// 도착지: 롱프레스 핀 좌표 우선, 없으면 검색창 지오코딩
  Future<void> _runNavSearch() async {
    _closeFilterMenus();
    final q = _searchCtrl.text.trim();
    final usePin = _canUsePinnedSearchDest(q);

    if (!usePin && q.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('도착지 주소를 입력하세요')),
      );
      return;
    }
    final origin = _pinnedNavOrigin ?? _myPos;
    if (origin == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('현재 위치를 확인할 수 없습니다. 위치 권한을 확인해 주세요.'),
        ),
      );
      return;
    }

    _onUserActivity();
    setState(() => _searching = true);

    LatLng? point;
    if (usePin) {
      point = _pinnedNavDest;
    } else {
      point = await context.read<MapProvider>().searchPlace(q);
    }

    if (!mounted) return;
    setState(() => _searching = false);

    if (point == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('검색 결과가 없습니다')),
      );
      return;
    }

    final nav = context.read<NavProvider>();
    if (nav.guiding || nav.arrived) {
      nav.cancelGuidanceForReplan();
    }
    if (!nav.active) {
      nav.toggleActive(myPos: origin);
    } else {
      nav.setOrigin(origin);
    }
    nav.setDestination(point);
    await nav.plan();
    _dismissLongPressMenu();
    _showNavPanel();
    if (!mounted) return;

    final mid = nav.selected?.points;
    final focus = (mid != null && mid.isNotEmpty)
        ? mid[mid.length ~/ 2]
        : point;
    await _loadAround(focus, 16);
  }

  bool get _panelExpanded =>
      (_panelHeightPx ?? _collapsedBarH) > _collapsedBarH + 8;

  double _maxPanelHeight(double screenH) =>
      (screenH * 0.65).clamp(280.0, screenH * 0.75);

  /// 카드 선택 등에 맞춘 기본 펼침 높이 (탭·드래그 끝 스냅용)
  double _defaultOpenHeight(double screenH, MapProvider map) {
    const headerH = _collapsedBarH;
    const textBlockWithDesc = 168.0;
    const textBlockTight = 96.0;
    const cardMargins = 36.0;
    const listPeek = 28.0;

    var hasSelection = false;
    var hasDescription = false;

    switch (_panelTab) {
      case MapPanelTab.report:
        if (_selectedReportId != null) {
          for (final r in map.reports) {
            if (r.id == _selectedReportId) {
              hasSelection = true;
              hasDescription = (r.description ?? '').trim().isNotEmpty;
              break;
            }
          }
        }
      case MapPanelTab.event:
        if (_selectedEventId != null) {
          for (final e in map.events) {
            if (e.id == _selectedEventId) {
              hasSelection = true;
              hasDescription =
                  formatEventDescription(e.description ?? e.title ?? '')
                      .isNotEmpty;
              break;
            }
          }
        }
      case MapPanelTab.nav:
        return (screenH * 0.38).clamp(220.0, _maxPanelHeight(screenH));
      case MapPanelTab.grid:
        if (map.selectedGridDetail != null) {
          return (screenH * 0.42).clamp(240.0, _maxPanelHeight(screenH));
        }
    }

    if (hasSelection) {
      final textH = hasDescription ? textBlockWithDesc : textBlockTight;
      final needed = headerH + cardMargins + textH + listPeek;
      return needed.clamp(screenH * 0.36, _maxPanelHeight(screenH));
    }

    return (screenH * _expandedFracBase).clamp(180.0, screenH * 0.48);
  }

  double _resolvePanelHeight(double screenH, MapProvider map) {
    final maxH = _maxPanelHeight(screenH);
    // 드래그 중엔 접힘~최대 사이 어디든 미리보기 (기본 펼침 지점을 넘어 더 끌어올릴 수 있음)
    if (_panelDragging) {
      final h = _panelHeightPx ?? _collapsedBarH;
      return h.clamp(_collapsedBarH, maxH);
    }
    if (!_panelExpanded) return _collapsedBarH;
    final resting = _panelHeightPx ?? _defaultOpenHeight(screenH, map);
    return resting.clamp(_collapsedBarH, maxH);
  }

  void _setPanelHeight(double h, {required double openH, bool drag = false}) {
    setState(() {
      _panelDragging = drag;
      _panelHeightPx = h.clamp(_collapsedBarH, openH);
    });
  }

  void _expandPanel({MapProvider? map}) {
    if (!mounted) return;
    final screenH = MediaQuery.sizeOf(context).height;
    final m = map ?? context.read<MapProvider>();
    final open = _defaultOpenHeight(screenH, m);
    _setPanelHeight(open, openH: open);
  }

  void _collapsePanel() {
    if (!mounted) return;
    setState(() {
      _panelDragging = false;
      _panelHeightPx = _collapsedBarH;
    });
  }

  void _openPanel(MapPanelTab tab) {
    _closeFilterMenus();
    _onUserActivity();
    final same = _panelTab == tab;
    final wasOpen = _panelExpanded;
    setState(() => _panelTab = tab);
    if (same && wasOpen) {
      _collapsePanel();
    } else {
      _expandPanel();
    }
  }
  void _showNavPanel() {
    _closeFilterMenus();
    _onUserActivity();
    setState(() => _panelTab = MapPanelTab.nav);
    _expandPanel();
  }

  void _onPanelDragUpdate(
    DragUpdateDetails details,
    double screenH,
    MapProvider map,
  ) {
    _onUserActivity();
    final maxH = _maxPanelHeight(screenH);
    final cur = _panelHeightPx ??
        (_panelExpanded ? _defaultOpenHeight(screenH, map) : _collapsedBarH);
    // 위로 드래그(dy < 0) → 확대. 기본 펼침 지점을 넘어 최대까지 끌어올릴 수 있음
    _setPanelHeight(cur - details.delta.dy, openH: maxH, drag: true);
  }

  void _onPanelDragEnd(
    DragEndDetails details,
    double screenH,
    MapProvider map,
  ) {
    _onUserActivity();
    final defaultH = _defaultOpenHeight(screenH, map);
    final maxH = _maxPanelHeight(screenH);
    final cur = _panelHeightPx ?? _collapsedBarH;
    final v = details.primaryVelocity ?? 0;

    // 접힘 / 기본 펼침(42%) / 최대 펼침 — 세 단계 스냅
    double target;
    if (v > 700) {
      // 아래로 플링 — 한 단계 아래로
      target = cur > defaultH ? defaultH : _collapsedBarH;
    } else if (v < -700) {
      // 위로 플링 — 한 단계 위로
      target = cur < defaultH ? defaultH : maxH;
    } else {
      // 가장 가까운 스냅 지점으로
      final points = [_collapsedBarH, defaultH, maxH];
      target = points.reduce(
        (a, b) => (cur - a).abs() <= (cur - b).abs() ? a : b,
      );
    }

    setState(() {
      _panelDragging = false;
      _panelHeightPx = target;
    });
  }

  Future<void> _onGridTap(int gridId) async {
    _onUserActivity();
    setState(() {
      _panelTab = MapPanelTab.grid;
      _selectedReportId = null;
    });
    await context.read<MapProvider>().selectGrid(gridId);
    if (!mounted) return;
    _expandPanel();
  }

  /// 마커 탭·패널 제보 카드 공통 선택 (지도 이동 + 사진 말풍선 + 패널 상세)
  void _selectReport(ReportItem r, {bool moveMap = true}) {
    if (moveMap) {
      _onMapUserGesture();
    } else {
      _onUserActivity();
    }
    setState(() {
      _selectedReportId = r.id;
      _selectedEventId = null;
      _panelTab = MapPanelTab.report;
    });
    _expandPanel();
    if (!moveMap) return;
    final p = tryLatLng(r.lat, r.lng);
    if (p != null) _focusMapOn(p, zoom: 16);
  }

  /// 마커 탭·패널 행사 카드 공통 선택
  void _selectEvent(CityEventItem e, {bool moveMap = true}) {
    if (moveMap) {
      _onMapUserGesture();
    } else {
      _onUserActivity();
    }
    setState(() {
      _selectedEventId = e.id;
      _selectedReportId = null;
      _panelTab = MapPanelTab.event;
    });
    _expandPanel();
    if (!moveMap) return;
    final p = tryLatLng(e.lat, e.lng);
    if (p != null) _focusMapOn(p, zoom: 16);
  }

  /// 하단 패널·탭 레일 위를 비워 둔 채 좌표를 가시 영역 중앙에 두기
  void _focusMapOn(LatLng point, {double zoom = 16}) {
    if (!mounted) return;
    final p = tryLatLng(point.latitude, point.longitude);
    if (p == null) return;

    final z = safeZoom(zoom);
    // 레이아웃 불안정 시 offset 계산 자체를 생략 (pixelBounds NaN 주원인)
    if (!_mapLayoutReady()) {
      _safeMapMove(p, z);
      return;
    }

    final media = MediaQuery.of(context);
    final screenH = media.size.height;
    if (!screenH.isFinite || screenH <= 0) {
      _safeMapMove(p, z);
      return;
    }

    final bottomPad = media.padding.bottom;
    final railH = 56.0 + (bottomPad.isFinite ? bottomPad : 0);
    final map = context.read<MapProvider>();
    final panelH = _resolvePanelHeight(screenH, map);
    final nav = context.read<NavProvider>();
    final guideH = nav.guiding ? NavGuidanceBar.estimatedHeight : 0.0;
    final freeH = (screenH - panelH - guideH - railH).clamp(120.0, screenH);

    final targetYFromTop = freeH * 0.58;
    final screenCenterY = screenH / 2;
    var offsetY = targetYFromTop - screenCenterY;
    if (!offsetY.isFinite) offsetY = 0;
    // 과도한 offset은 투영 깨질 수 있음
    final mapH = _mapController.camera.nonRotatedSize.height;
    final maxOff = mapH * 0.4;
    if (offsetY.abs() > maxOff) {
      offsetY = offsetY.sign * maxOff;
    }

    _safeMapMove(p, z, offset: Offset(0, offsetY));
  }

  /// 카메라 이동 — size 준비·offset 검증·실패 시 remount
  void _safeMapMove(LatLng point, double zoom, {Offset offset = Offset.zero}) {
    final p = tryLatLng(point.latitude, point.longitude);
    if (p == null) return;
    final z = safeZoom(zoom);
    var off = Offset(
      offset.dx.isFinite ? offset.dx : 0,
      offset.dy.isFinite ? offset.dy : 0,
    );

    if (!_mapLayoutReady()) {
      // 다음 프레임에 한 번 더 시도 (키보드/리사이즈 직후)
      _pendingMove = (p, z, off);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pending = _pendingMove;
        if (pending == null) return;
        _pendingMove = null;
        if (_mapLayoutReady()) {
          _applyMapMove(pending.$1, pending.$2, pending.$3);
        } else {
          // still not ready — plain move may still corrupt; skip offset only
          _applyMapMove(pending.$1, pending.$2, Offset.zero);
        }
      });
      return;
    }

    if (!_cameraHealthy()) {
      _remountMap(preferCenter: p, preferZoom: z);
      return;
    }

    _applyMapMove(p, z, off);
  }

  void _applyMapMove(LatLng p, double z, Offset off) {
    // offset move는 레이아웃·카메라가 건강할 때만
    final useOffset = off != Offset.zero && _mapLayoutReady() && _cameraHealthy();
    _programmaticCamera = true;
    try {
      if (useOffset) {
        _mapController.move(p, z, offset: off);
      } else {
        _mapController.move(p, z);
      }
      if (!_cameraHealthy()) {
        // offset이 카메라를 망가뜨린 경우 plain으로 복구 시도 후 remount
        try {
          _mapController.move(p, z);
        } catch (_) {}
        if (!_cameraHealthy()) {
          _remountMap(preferCenter: p, preferZoom: z);
          return;
        }
      }
      if (mounted) {
        context.read<MapProvider>().setZoom(z);
        context.read<MapProvider>().setCenter(p);
      }
    } catch (_) {
      try {
        _mapController.move(p, z);
        context.read<MapProvider>().setZoom(z);
        context.read<MapProvider>().setCenter(p);
      } catch (_) {
        _remountMap(preferCenter: p, preferZoom: z);
      }
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _programmaticCamera = false;
      });
    }
  }

  void _clearFeatureSelection() {
    if (_selectedReportId == null && _selectedEventId == null) return;
    setState(() {
      _selectedReportId = null;
      _selectedEventId = null;
    });
  }

  String _formatRange(String? a, String? b) {
    String short(String? s) {
      if (s == null || s.isEmpty) return '-';
      final t = s.replaceFirst('T', ' ');
      return t.length >= 16 ? t.substring(5, 16) : t;
    }

    return '${short(a)} ~ ${short(b)}';
  }

  Widget _buildBottomPanelBody({
    required MapProvider map,
    required double screenH,
    required bool nestInParent,
  }) {
    return _PanelBody(
    tab: _panelTab,
    expanded: _panelExpanded,
    map: map,
    selectedReportId: _selectedReportId,   // ← 추가
    selectedEventId: _selectedEventId,
    myPos: _myPos,
    onGuidanceStarted: _onGuidanceStartedFromSheet,
    onRoutePreview: _fitSelectedRoute,   // ← 오타 수정
    onUserActivity: _onUserActivity,
    onSelectReport: (r) => _selectReport(r, moveMap: true),
    onSelectEvent: (e) => _selectEvent(e, moveMap: true),
    // onSelectMyReport 삭제
    formatRange: _formatRange,
    onDragUpdate: (d) => _onPanelDragUpdate(d, screenH, map),
    onDragEnd: (d) => _onPanelDragEnd(d, screenH, map),
    nestInParent: nestInParent,
    );
  }

  void _onGuidanceStartedFromSheet() {
    context.read<MapProvider>().setGridsVisible(false);
    _followZoomOverride = _myLocationZoom;
    _enableFollowAndCenter(zoom: _myLocationZoom);
    _wasGuiding = true;
    _wasArrived = false;
    unawaited(_restartLocationTracking(forGuidance: true));
    unawaited(_syncGuidanceNotification(context.read<NavProvider>()));
  }

  @override
  Widget build(BuildContext context) {
    final map = context.watch<MapProvider>();
    final auth = context.watch<AuthProvider>();
    final nav = context.watch<NavProvider>();
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final screenH = MediaQuery.sizeOf(context).height;
    final railH = 56.0 + bottomPad;
    final panelH = _resolvePanelHeight(screenH, map);
    final panelExpanded = _panelExpanded || _panelDragging;
    // FAB: 합쳐진 하단 스택(경로선택/안내+격자) 바로 위

    // FAB: 하단 패널 바로 위
    const fabNavGap = 10.0;
    final fabBottom = railH + panelH + fabNavGap;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPress != null &&
            now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
          SystemNavigator.pop();
          return;
        }
        _lastBackPress = now;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('버튼을 한 번 더 누르면 종료됩니다'),
              duration: Duration(seconds: 2),
            ),
          );
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F5F9),
        body: Stack(
        children: [
          // 맵
          Positioned.fill(
            child: FlutterMap(
              key: ValueKey<int>(_mapGeneration),
            mapController: _mapController,
            options: MapOptions(
                initialCenter: coerceLatLng(
                  map.center.latitude,
                  map.center.longitude,
                ),
                initialZoom: safeZoom(map.zoom),
                minZoom: kMapMinZoom,
                maxZoom: kMapMaxZoom,
                interactionOptions: const InteractionOptions(
                  // 두 손가락 회전 시 타일·폴리곤 부하 증가 → 비활성
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
              onMapEvent: (e) {
                  // 카메라 붕괴 조기 감지 → remount (TileLayer NaN 예방)
                  _ensureCameraHealthyOrRemount(e.camera);

                if (!_programmaticCamera &&
                    e.source != MapEventSource.mapController &&
                    _isUserMapGestureSource(e.source)) {
                  _onMapUserGesture();
                }

                if (e is MapEventMoveEnd) {
                  final cam = e.camera;
                    if (!_cameraHealthy()) return;
                    final c = tryLatLng(
                      cam.center.latitude,
                      cam.center.longitude,
                    );
                    final z = safeZoom(cam.zoom);
                    if (c == null) return;
                    context.read<MapProvider>().setZoom(z);
                    // follow 중 자동 카메라는 setCenter 스킵
                    // (_syncFollowCamera 1초 throttle 과 정합; 전체 rebuild 억제)
                    final programmaticFollow = _followMe &&
                        (_programmaticCamera ||
                            e.source == MapEventSource.mapController);
                    if (!programmaticFollow) {
                      context.read<MapProvider>().setCenter(c);
                    }
                    // follow 중 자동 이동은 뷰포트 로드 과다 → 사용자 이동 끝만 조회
                    if (!_followMe ||
                        (!_programmaticCamera &&
                            e.source != MapEventSource.mapController)) {
                      _scheduleLoadAround(c, z);
                    }
                }
              },
              onTap: (_, latLng) {
                  if (!isValidLatLng(latLng.latitude, latLng.longitude)) {
                    return;
                  }
                  if (_longPressPoint != null) {
                    _dismissLongPressMenu();
                    return;
                  }
                  _onUserActivity();
                  _clearFeatureSelection();
                final mp = context.read<MapProvider>();
                GridItem? hit;
                var best = double.infinity;
                  for (final g in mp.displayGrids) {
                    if (!isValidLatLng(g.lat, g.lng)) continue;
                  final d = (g.lat! - latLng.latitude).abs() +
                      (g.lng! - latLng.longitude).abs();
                  if (d < best) {
                    best = d;
                    hit = g;
                  }
                }
              if (hit != null && best.isFinite && best < Env.gridCellDeg) {
                  _onGridTap(hit.gridId);
                }
              },
              onLongPress: (_, latLng) {
                unawaited(_openLongPressMenu(latLng));
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.publicsafetymap.app',
              ),
              if (map.gridsVisible)
                PolygonLayer(
                  polygons: [
                      for (final g in map.displayGrids)
                        if (isValidLatLng(g.lat, g.lng))
                        Polygon(
                          points: _cellCorners(g.lat!, g.lng!),
                          color: gradeColor(g.safetyGrade),
                            borderColor: gradeBorderColor(g.safetyGrade),
                            borderStrokeWidth: 0.9,
                        ),
                  ],
                ),
              if (map.accidentZonesVisible)
                PolygonLayer(
                  polygons: [
                      for (final z in map.displayAccidentZones)
                        if (z.path.where((p) => isValidLatLng(p.lat, p.lng)).length >=
                            3)
                        Polygon(
                            points: [
                              for (final p in z.path)
                                if (isValidLatLng(p.lat, p.lng))
                                  LatLng(p.lat, p.lng),
                            ],
                            color: accidentZoneColor(z.type)
                                .withValues(alpha: 0.25),
                            borderColor: accidentZoneColor(z.type)
                                .withValues(alpha: 0.9),
                            borderStrokeWidth: 2,
                        ),
                  ],
                ),
              const NavRouteLayer(),
              const NavOriginMarker(),
              const NavDestinationMarker(),
              if (_longPressPoint != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _longPressPoint!,
                      width: 36,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: const Icon(
                        Icons.location_on,
                        color: MapUiColors.accent,
                        size: 36,
                        shadows: [
                          Shadow(
                            color: Colors.black38,
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                    Marker(
                      point: _longPressPoint!,
                      width: 280,
                      height: 168,
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 30),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.bottomCenter,
                          child: LongPressMapMenu(
                          address: _longPressAddress,
                          loading: _longPressAddressLoading,
                          onOrigin: _onLongPressSetOrigin,
                          onDestination: () {
                            unawaited(_onLongPressSetDestination());
                          },
                          onCopyAddress: () {
                            unawaited(_onLongPressCopyAddress());
                          },
                          onClose: _dismissLongPressMenu,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                    // 제보: 핀 + 선택 시 사진 말풍선
                  for (final r in map.reports)
                      if (tryLatLng(r.lat, r.lng) case final point?)
                      Marker(
                          point: point,
                          width: (r.id == _selectedReportId &&
                                  resolveMediaUrl(r.imgUrl) != null)
                              ? kFeatureBubbleMarkerWidth
                              : kFeaturePinMarkerSize,
                          height: (r.id == _selectedReportId &&
                                  resolveMediaUrl(r.imgUrl) != null)
                              ? kFeatureBubbleMarkerHeight
                              : kFeaturePinMarkerSize,
                          alignment: Alignment.bottomCenter,
                          child: ReportMapMarker(
                            type: r.type,
                            imgUrl: r.imgUrl,
                            selected: r.id == _selectedReportId,
                            onTap: () => _selectReport(r, moveMap: true),
                            onCloseBubble: _clearFeatureSelection,
                          ),
                        ),
                    // 행사: 동일 패턴 (분홍 핀 + 말풍선)
                  for (final e in map.events)
                      if (tryLatLng(e.lat, e.lng) case final point?)
                      Marker(
                          point: point,
                          width: (e.id == _selectedEventId &&
                                  resolveMediaUrl(e.imgUrl) != null)
                              ? kFeatureBubbleMarkerWidth
                              : kFeaturePinMarkerSize,
                          height: (e.id == _selectedEventId &&
                                  resolveMediaUrl(e.imgUrl) != null)
                              ? kFeatureBubbleMarkerHeight
                              : kFeaturePinMarkerSize,
                          alignment: Alignment.bottomCenter,
                          child: EventMapMarker(
                            type: e.type,
                            title: e.title,
                            imgUrl: e.imgUrl,
                            selected: e.id == _selectedEventId,
                            onTap: () => _selectEvent(e, moveMap: true),
                            onCloseBubble: _clearFeatureSelection,
                          ),
                        ),
                    // 인프라: CCTV는 줌별 클러스터, 나머지 개별
                    for (final p in buildInfraMapPoints(
                      items: map.displayInfras,
                      zoom: map.zoom,
                    ))
                      if (p.latLng case final point?)
                        Marker(
                          point: point,
                          width: p.isCluster ? 40 : 26,
                          height: p.isCluster ? 40 : 26,
                          alignment: Alignment.center,
                          child: p.isCluster
                              ? GestureDetector(
                                  onTap: () {
                                    // 한 단계 확대 → 셀이 쪼개지며 상세 확인
                                    _onMapUserGesture();
                                    final z = safeZoom(map.zoom + 1.2);
                                    _safeMapMove(point, z);
                                  },
                                  child: CctvClusterBadge(count: p.count),
                                )
                              : Icon(
                                  infraMarkerIcon(p.item?.type),
                                  color: infraMarkerColor(p.item?.type),
                                  size: 20,
                                ),
                        ),
                ],
              ),
              // 내 위치 — 전용 ValueListenable (격자/제보 레이어와 분리 repaint)
              ValueListenableBuilder<_MyLocPaint>(
                valueListenable: _myLocPaint,
                builder: (context, paint, _) {
                  final myPoint = paint.pos;
                  if (myPoint == null) {
                    return const MarkerLayer(markers: []);
                  }
                  return MarkerLayer(
                    markers: [
                      Marker(
                        point: myPoint,
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        child: _MyLocationDot(headingRad: paint.headingRad),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
          ),
          // 상단 바: 내정보 + 검색 + 칩
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                  Row(
                    children: [
                      Expanded(
                        child: Material(
                          elevation: 3,
                          shadowColor: Colors.black38,
                          surfaceTintColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          color: Colors.white,
                          clipBehavior: Clip.antiAlias,
                    child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: '길찾기',
                                  onPressed:
                                      _searching ? null : _runNavSearch,
                                  icon: Icon(
                                    Icons.directions,
                                    color: nav.active
                                        ? MapUiColors.accent
                                        : const Color(0xFF0F172A),
                                  ),
                                ),
                                Expanded(
                                  child: TextField(
                                    controller: _searchCtrl,
                                    style: const TextStyle(
                                      color: Color(0xFF0F172A),
                                      fontSize: 15,
                                    ),
                                    cursorColor: MapUiColors.accent,
                                    onTap: _onUserActivity,
                                    onChanged: _onSearchTextChanged,
                                    decoration: const InputDecoration(
                                      hintText: '장소 검색 · 길찾기 도착지',
                                      hintStyle: TextStyle(
                                        color: Color(0xFF64748B),
                                        fontSize: 15,
                                      ),
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      filled: false,
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 10,
                                      ),
                                    ),
                                    textInputAction: TextInputAction.search,
                                    onSubmitted: (_) => _runSearch(),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _searching ? null : _runSearch,
                                  style: TextButton.styleFrom(
                                    foregroundColor: MapUiColors.accent,
                                    disabledForegroundColor:
                                        const Color(0xFF94A3B8),
                                  ),
                                  child: _searching
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: MapUiColors.accent,
                                          ),
                                        )
                                      : const Text(
                                          '검색',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: MapUiColors.accent,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        elevation: 3,
                        shadowColor: Colors.black38,
                        surfaceTintColor: Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white,
                        clipBehavior: Clip.antiAlias,
                        child: IconButton(
                          tooltip: auth.isLoggedIn ? '내정보' : '로그인',
                          onPressed: () {
                            _closeFilterMenus();
                            if (auth.isLoggedIn) {
                              context.push('/mypage');
                            } else {
                              context.push('/login');
                            }
                          },
                          icon: Icon(
                            auth.isLoggedIn ? Icons.person : Icons.person_outlined,
                            color: MapUiColors.accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _TopChip(
                          label: map.infraVisible
                              ? (map.visibleInfraTypes.length ==
                                      kInfraTypes.length
                                  ? '인프라'
                                  : '인프라 · ${map.visibleInfraTypes.length}종')
                              : '인프라',
                          selected: map.infraVisible,
                          onTap: () {
                            _onUserActivity();
                            setState(() {
                              _nearbyMenu = !_nearbyMenu;
                              _gridMenu = false;
                              _accidentMenu = false;
                            });
                          },
                          onLongPress: () {
                            _onUserActivity();
                            context.read<MapProvider>().toggleInfra();
                          },
                        ),
                        const SizedBox(width: 6),
                        _TopChip(
                          label: map.gridsVisible
                              ? (map.visibleGrades.length == kSafetyGrades.length
                                  ? '격자'
                                  : '격자 · ${map.visibleGrades.length}종')
                              : '격자',
                          selected: map.gridsVisible,
                          onTap: () {
                            _onUserActivity();
                            setState(() {
                              _gridMenu = !_gridMenu;
                              _nearbyMenu = false;
                              _accidentMenu = false;
                            });
                          },
                          onLongPress: () {
                            _onUserActivity();
                            context.read<MapProvider>().toggleGrids();
                          },
                        ),
                        const SizedBox(width: 6),
                        _TopChip(
                          label: _accidentChipLabel(map),
                          selected: map.accidentZonesVisible,
                          onTap: () {
                            _onUserActivity();
                            setState(() {
                              _accidentMenu = !_accidentMenu;
                              _nearbyMenu = false;
                              _gridMenu = false;
                            });
                          },
                          onLongPress: () {
                            _onUserActivity();
                            _toggleAccidentZonesUi();
                          },
                        ),
                        if (map.loading) ...[
                          const SizedBox(width: 8),
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_nearbyMenu) _NearbyFilterRow(map: map),
                  if (_gridMenu) _GridFilterRow(map: map),
                  if (_accidentMenu)
                    _AccidentFilterRow(
                      map: map,
                      onToggle: _toggleAccidentZonesUi,
                    ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Column(
                        children: [
                          Consumer<NearbyMonitor>(
                            builder: (context, monitor, _) {
                              final on = monitor.enabled;
                              return Tooltip(
                                message: on ? '주변알림 ON' : '주변알림',
                                child: Material(
                                  elevation: 3,
                                  shape: const CircleBorder(),
                                  color: Colors.white,
                                  shadowColor: Colors.black38,
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: monitor.busy
                                        ? null
                                        : () {
                                            _closeFilterMenus();
                                            _onUserActivity();
                                            unawaited(_toggleNearbyMonitor());
                                          },
                                    child: SizedBox(
                                      width: 40,
                                      height: 40,
                                      child: monitor.busy
                                          ? const Padding(
                                              padding: EdgeInsets.all(10),
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: MapUiColors.accent,
                                              ),
                                            )
                                          : Icon(
                                              on
                                                  ? Icons.notifications_active
                                                  : Icons.notifications_none,
                                              color: on
                                                  ? MapUiColors.accent
                                                  : const Color(0xFF0F172A),
                                              size: 20,
                                            ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 8),
                          Material(
                            elevation: 3,
                            shape: const CircleBorder(),
                            color: Colors.white,
                            shadowColor: Colors.black38,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () {
                                _closeFilterMenus();
                                if (!auth.isLoggedIn) {
                                  context.push('/login');
                                  return;
                                }
                                context.push('/report/create', extra: _myPos);
                              },
                              child: const SizedBox(
                                width: 40,
                                height: 40,
                                child: Icon(
                                  Icons.add_location_alt,
                                  color: Color(0xFF0F172A),
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (map.error != null)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        map.error!,
                        style: TextStyle(
                          color: Colors.red.shade800,
                          fontSize: 12,
                        ),
            ),
          ),
        ],
      ),
            ),
          ),

          // 하단: 경로선택/안내 + 격자 패널을 한 Material로 (빈 틈 없이)
          Positioned(
            left: 0,
            right: 0,
            bottom: railH,
            child: AnimatedContainer(
              duration: _panelDragging
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              height: panelH,
              child: panelExpanded
                  ? SizedBox(
                      height: panelH,
                      child: _buildBottomPanelBody(
                        map: map,
                        screenH: screenH,
                        nestInParent: false,
                      ),
                    )
                  : _buildBottomPanelBody(
                      map: map,
                      screenH: screenH,
                      nestInParent: false,
                    ),
            ),
          ),

          // 내 위치 FAB — 네이버 지도 스타일 (지도 우측 하단, 아이콘 전용 원형)
          AnimatedPositioned(
            duration: _panelDragging
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            right: 12,
            bottom: fabBottom,
            child: Tooltip(
              message: '내 위치',
              child: Material(
                elevation: 4,
                shape: const CircleBorder(),
                color: Colors.white,
                shadowColor: Colors.black38,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _myLocation,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      _followMe ? Icons.gps_fixed : Icons.my_location,
                      color: _followMe
                          ? MapUiColors.accent
                          : const Color(0xFF0F172A),
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 하단 4탭 레일
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              elevation: 8,
              color: Colors.white,
              shadowColor: Colors.black26,
              child: SafeArea(
                top: false,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: Color(0xFFE2E8F0), width: 1),
                    ),
                  ),
        child: SizedBox(
                    height: 56,
                    child: Row(
            children: [
                        _RailTab(
                          iconSelected: Icons.grid_view,
                          iconUnselected: Icons.grid_view_outlined,
                          label: '격자',
                          selected: _panelTab == MapPanelTab.grid,
                          onTap: () => _openPanel(MapPanelTab.grid),
                        ),
                        _RailTab(
                          iconSelected: Icons.event,
                          iconUnselected: Icons.event_outlined,
                          label: '행사',
                          selected: _panelTab == MapPanelTab.event,
                          onTap: () => _openPanel(MapPanelTab.event),
                        ),
                        _RailTab(
                          iconSelected: Icons.report,
                          iconUnselected: Icons.report_outlined,
                          label: '제보',
                          selected: _panelTab == MapPanelTab.report,
                          onTap: () => _openPanel(MapPanelTab.report),
                        ),
                      _RailTab(
                        iconSelected: Icons.directions,
                        iconUnselected: Icons.directions_outlined,
                        label: '길찾기',
                        selected: _panelTab == MapPanelTab.nav,
                        onTap: () => _openPanel(MapPanelTab.nav),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
          // 마이페이지 「위치로 이동」 대기 스피너
          if (map.mapFocusing)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }

  List<LatLng> _cellCorners(double lat, double lng) {
    const h = Env.gridCellDeg / 2;
    return [
      LatLng(lat - h, lng - h),
      LatLng(lat - h, lng + h),
      LatLng(lat + h, lng + h),
      LatLng(lat + h, lng - h),
    ];
  }

}

// --- UI bits ---

/// 내 위치 마커 페인트 스냅샷 (ValueNotifier 페이로드)
class _MyLocPaint {
  const _MyLocPaint({this.pos, this.headingRad = 0});

  final LatLng? pos;
  final double headingRad;
}

class _TopChip extends StatelessWidget {
  const _TopChip({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.onLongPress,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  static const _textOn = Color(0xFF0F172A);
  static const _borderOff = Color(0xFFCBD5E1);
  static const _bgOn = Color(0xFFDBEAFE);

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? MapUiColors.accent : _borderOff;
    final fg = selected ? MapUiColors.accent : _textOn;

    return Material(
      elevation: 3,
      shadowColor: Colors.black38,
      surfaceTintColor: Colors.transparent,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? _bgOn : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: DefaultTextStyle(
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: fg,
              height: 1.2,
            ),
            child: IconTheme(
              data: IconThemeData(size: 15, color: fg),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NearbyFilterRow extends StatelessWidget {
  const _NearbyFilterRow({required this.map});
  final MapProvider map;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          chipTheme: ChipThemeData(
            backgroundColor: Colors.white,
            selectedColor: const Color(0xFFDBEAFE),
            labelStyle: const TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            secondaryLabelStyle: const TextStyle(
              color: MapUiColors.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
            side: const BorderSide(color: Color(0xFFCBD5E1)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            checkmarkColor: MapUiColors.accent,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            FilterChip(
              label: Text(map.infraVisible ? '표시 중' : '숨김'),
              selected: map.infraVisible,
              onSelected: (_) => context.read<MapProvider>().toggleInfra(),
            ),
            for (final t in kInfraTypes)
              FilterChip(
                avatar: Icon(
                  infraMarkerIcon(t),
                  size: 16,
                  color: map.visibleInfraTypes.contains(t)
                      ? MapUiColors.accent
                      : const Color(0xFF64748B),
                ),
                showCheckmark: false,
                label: Text(t),
                selected: map.visibleInfraTypes.contains(t),
                onSelected: (_) =>
                    context.read<MapProvider>().toggleInfraType(t),
              ),
          ],
        ),
      ),
    );
  }
}

class _GridFilterRow extends StatelessWidget {
  const _GridFilterRow({required this.map});
  final MapProvider map;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          chipTheme: ChipThemeData(
            backgroundColor: Colors.white,
            selectedColor: const Color(0xFFDBEAFE),
            labelStyle: const TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            secondaryLabelStyle: const TextStyle(
              color: MapUiColors.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
            side: const BorderSide(color: Color(0xFFCBD5E1)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            checkmarkColor: MapUiColors.accent,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            FilterChip(
              label: Text(map.gridsVisible ? '표시 중' : '숨김'),
              selected: map.gridsVisible,
              onSelected: (_) => context.read<MapProvider>().toggleGrids(),
            ),
            for (final g in kSafetyGrades)
              FilterChip(
                label: Text(g),
                selected: map.visibleGrades.contains(g),
                onSelected: (_) =>
                    context.read<MapProvider>().toggleGradeFilter(g),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccidentFilterRow extends StatelessWidget {
  const _AccidentFilterRow({required this.map, required this.onToggle});
  final MapProvider map;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          chipTheme: ChipThemeData(
            backgroundColor: Colors.white,
            selectedColor: const Color(0xFFDBEAFE),
            labelStyle: const TextStyle(
              color: Color(0xFF0F172A),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            secondaryLabelStyle: const TextStyle(
              color: MapUiColors.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
            side: const BorderSide(color: Color(0xFFCBD5E1)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            checkmarkColor: MapUiColors.accent,
            surfaceTintColor: Colors.transparent,
          ),
        ),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            FilterChip(
              label: Text(
                map.accidentZonesVisible ? '위험구간 ON' : '위험구간 OFF',
              ),
              selected: map.accidentZonesVisible,
              onSelected: (_) => onToggle(),
            ),
            for (final t in kAccidentZoneTypes)
              FilterChip(
                avatar: CircleAvatar(
                  backgroundColor: accidentZoneColor(t),
                  radius: 6,
                ),
                label: Text(kAccidentZoneLabel[t] ?? t),
                selected: map.visibleAccidentTypes.contains(t),
                onSelected: map.accidentZonesVisible
                    ? (_) => context.read<MapProvider>().toggleAccidentType(t)
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _MyLocationDot extends StatelessWidget {
  const _MyLocationDot({required this.headingRad});

  final double headingRad;

  @override
  Widget build(BuildContext context) {
    final accent = MapUiColors.accent;
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 진행 방향 (북쪽 0 = 위, Transform은 반시계 기준 → heading 라디안 그대로 사용)
          Transform.rotate(
            angle: headingRad,
            child: Align(
              alignment: const Alignment(0, -0.85),
              child: CustomPaint(
                size: const Size(12, 10),
                painter: _HeadingChevronPainter(color: accent),
              ),
            ),
          ),
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.35),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeadingChevronPainter extends CustomPainter {
  _HeadingChevronPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    // package 측 Path<LatLng> 와 구분
    final path = ui.Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width / 2, size.height * 0.65)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _HeadingChevronPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _RailTab extends StatelessWidget {
  const _RailTab({
    required this.iconSelected,
    required this.iconUnselected,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData iconSelected;
  final IconData iconUnselected;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  static const _selectedColor = Colors.black;
  static const _unselectedColor = Color(0xFF94A3B8);

  @override
  Widget build(BuildContext context) {
    final color = selected ? _selectedColor : _unselectedColor;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? iconSelected : iconUnselected, color: color, size: 22),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({
  required this.tab,
  required this.expanded,
  required this.map,
  required this.selectedReportId,
  required this.selectedEventId,
  required this.myPos,
  required this.onGuidanceStarted,
  required this.onRoutePreview,
  required this.onUserActivity,
  required this.onSelectReport,
  required this.onSelectEvent,
  required this.formatRange,
  required this.onDragUpdate,
  required this.onDragEnd,
  this.nestInParent = false,
  });

  final int? selectedReportId;
  final int? selectedEventId;
  final LatLng? myPos;
  final VoidCallback onGuidanceStarted;
  final VoidCallback onRoutePreview;
  final MapPanelTab tab;
  final bool expanded;
  final MapProvider map;
  final VoidCallback onUserActivity;
  final void Function(ReportItem) onSelectReport;
  final void Function(CityEventItem) onSelectEvent;
  final String Function(String?, String?) formatRange;
  final void Function(DragUpdateDetails) onDragUpdate;
  final void Function(DragEndDetails) onDragEnd;
  final bool nestInParent;

  String get _title => switch (tab) {
        MapPanelTab.grid => '격자 정보',
        MapPanelTab.event => '행사 · 도시정보',
        MapPanelTab.report => '제보',
        MapPanelTab.nav => '길찾기',
      };

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
      children: [
        // 핸들·제목: 고정 높이 없이 내용만큼 (오버플로 방지)
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: onDragUpdate,
          onVerticalDragEnd: onDragEnd,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF94A3B8),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          height: 1.2,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          const Divider(height: 1),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification ||
                    n is ScrollStartNotification) {
                  onUserActivity();
                }
                return false;
              },
              child: _buildContent(context),
            ),
          ),
        ],
      ],
    );

    if (nestInParent) return body;

    return Material(
      elevation: 10,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (tab) {
      case MapPanelTab.grid:
        return _GridPanel(map: map);
      case MapPanelTab.event:
        if (map.events.isEmpty) {
          return const Center(child: Text('표시할 도시정보가 없습니다'));
        }
        final events = [
          ...map.events.where((e) => e.id == selectedEventId),
          ...map.events.where((e) => e.id != selectedEventId),
        ];
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 12),
          itemCount: events.length,
          itemBuilder: (_, i) {
            final e = events[i];
            return EventListCard(
              title: e.title ?? e.type ?? '행사',
              description: formatEventDescription(e.description),
              meta: formatRange(e.startAt, e.endAt),
              selected: selectedEventId == e.id,
              onTap: () => onSelectEvent(e),
            );
          },
        );
      case MapPanelTab.report:
        if (map.reports.isEmpty) {
          return const Center(child: Text('표시할 제보가 없습니다'));
        }
        final reports = [
          ...map.reports.where((r) => r.id == selectedReportId),
          ...map.reports.where((r) => r.id != selectedReportId),
        ];
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: reports.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            final r = reports[i];
            final desc = (r.description ?? '').trim();
            return ReportListCard(
              title: '[${r.type ?? '제보'}] $desc',
              meta: _formatListDateTime(r.createdAt),
              selected: selectedReportId == r.id,
              onTap: () => onSelectReport(r),
            );
          },
        );
        case MapPanelTab.nav:
        final nav = context.watch<NavProvider>();

        if (nav.guiding) {
          return NavGuidanceBar(nav: nav, myPos: myPos);
        }
        if (nav.active) {
          return NavSheet(
            myPos: myPos,
            embedInParent: true,
            onGuidanceStarted: onGuidanceStarted,
            onRoutePreview: onRoutePreview,
          );
        }
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '도착지를 정한 뒤 경로를 비교할 수 있습니다.\n\n'
              '· 위 검색창에 장소를 입력하고 길찾기\n'
              '· 지도를 길게 눌러 출발 또는 도착 지정',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF64748B), height: 1.5),
            ),
          ),
        );
    }
  }
}

class _GridPanel extends StatelessWidget {
  const _GridPanel({required this.map});
  final MapProvider map;

  @override
  Widget build(BuildContext context) {
    final d = map.selectedGridDetail;
    if (d == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '지도에서 격자 셀을 탭하면\n상세 정보가 표시됩니다',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF64748B)),
          ),
        ),
      );
    }

    final stats = map.infraStatsForSelectedGrid();
    final grade = d.safetyGrade ?? '-';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            boxShadow: const [
              BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '격자 #${d.gridId}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _gradeLine(grade),
                    const SizedBox(height: 8),
                    Text(
                      '인프라 ${d.infraCount ?? 0}개',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF334155),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'CCTV ${stats['CCTV'] ?? 0} · 경찰서 ${stats['경찰서'] ?? 0} · '
                      '소방서 ${stats['소방서'] ?? 0} · 편의점 ${stats['편의점'] ?? 0}',
                      style:
                          const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '활성 제보',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 6),
              if (d.activeReports.isEmpty)
                const Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: 18, color: Color(0xFF94A3B8)),
                    SizedBox(width: 6),
                    Text('없음', style: TextStyle(color: Color(0xFF94A3B8))),
                  ],
                )
              else
                ...d.activeReports.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      width: double.infinity,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Text(
                        '[${r['type'] ?? '제보'}] ${r['description'] ?? ''}',
                        style: const TextStyle(fontSize: 13, color: Color(0xFF334155)),
                      ),
                    ),
                  ),
                ),
              if (d.tags.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text(
                  '태그',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 8),
                ...d.tags.map((t) {
                  final max =
                      d.tags.map((x) => x.count).fold<int>(1, (a, b) => a > b ? a : b);
                  final ratio = (t.count / max).clamp(0.12, 1.0);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          Container(
                            height: 36,
                            color: const Color(0xFFF1F5F9),
                          ),
                          FractionallySizedBox(
                            widthFactor: ratio,
                            child: Container(
                              height: 36,
                              color: const Color(0xFFA5F3FC),
                            ),
                          ),
                          Positioned.fill(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '"${t.name}"',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${t.count}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF0E7490),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
              if (d.recentFeedbacks.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text(
                  '최근 피드백',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 6),
                ...d.recentFeedbacks.take(3).map((fb) {
                  final feeling = fb['safety_feeling']?.toString() ?? '';
                  final comment = fb['comment']?.toString() ?? '';
                  final line = [
                    if (feeling.isNotEmpty) feeling,
                    if (comment.isNotEmpty) comment,
                  ].join(' · ');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      width: double.infinity,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Text(
                        line.isEmpty ? '피드백' : line,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF334155),
                        ),
                      ),
                    ),
                  );
                }),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  final auth = context.read<AuthProvider>();
                  if (!auth.isLoggedIn) {
                    context.push('/login');
                    return;
                  }
                  context.push('/feedback/create/${d.gridId}');
                },
                icon: const Icon(Icons.rate_review_outlined, size: 18),
                label: const Text('피드백 작성'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _gradeLine(String grade) {
    Color bg;
    Color fg;
    switch (grade) {
      case '안전':
        bg = const Color(0xFFDCFCE7);
        fg = const Color(0xFF166534);
      case '보통':
        bg = const Color(0xFFFEF9C3);
        fg = const Color(0xFF854D0E);
      case '불안':
        bg = const Color(0xFFFEE2E2);
        fg = const Color(0xFF991B1B);
      default:
        bg = const Color(0xFFF1F5F9);
        fg = const Color(0xFF475569);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        grade,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}
