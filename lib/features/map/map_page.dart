import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/config/env.dart';
import '../../core/config/media_url.dart';
import '../../core/format/event_text.dart';
import '../../core/geo/geo_utils.dart';
import '../../core/network/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../data/repositories/mypage_repository.dart';
import '../../providers/auth_provider.dart';
import '../../providers/map_provider.dart';
import '../../services/nearby_monitor.dart';
import '../../services/nearby_report_alert.dart';
import '../../widgets/infra_cluster.dart';
import '../../widgets/media_image.dart';
import '../../widgets/report_markers.dart';

/// 하단 패널 탭 (웹 좌측 레일: 격자 / 행사 / 제보 / 내 제보)
enum MapPanelTab { grid, event, report, myReport }

String _accidentChipLabel(MapProvider map) {
  if (!map.accidentZonesVisible) return '위험구간 · 숨김';
  final n = map.visibleAccidentTypes.length;
  if (n == kAccidentZoneTypes.length) return '위험구간';
  if (n == 0) return '위험구간 · 없음';
  if (n == 1) {
    final t = map.visibleAccidentTypes.first;
    return '위험구간 · ${kAccidentZoneLabel[t] ?? t}';
  }
  return '위험구간 · $n종';
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  MapController _mapController = MapController();
  final _searchCtrl = TextEditingController();
  bool _booted = false;
  bool _searching = false;
  /// FlutterMap 재마운트용 (카메라 NaN 복구)
  int _mapGeneration = 0;
  bool _remountingMap = false;
  /// layout 준비 전 deferred move
  (LatLng, double, Offset)? _pendingMove;
  /// pan/zoom 종료 후 격자·제보·행사 재조회 debounce
  Timer? _viewportDebounce;
  static const _viewportDebounceMs = 700;

  /// 실시간 내 위치 마커
  LatLng? _myPos;
  StreamSubscription<Position>? _posSub;
  /// 정지 중에도 새 제보 감지 (위치 필터만으로는 부족)
  Timer? _nearbyAlertTimer;
  /// 알림 탭 → 해당 제보 열기
  StreamSubscription<int>? _openReportSub;
  StreamSubscription<AccidentZoneItem>? _openAccidentSub;

  MapPanelTab _panelTab = MapPanelTab.grid;
  /// 하단 패널 높이(px). null 이면 접힘(헤더만).
  double? _panelHeightPx;
  /// 드래그 중이면 높이 애니 끄기
  bool _panelDragging = false;

  static const double _collapsedBarH = 52;
  static const double _expandedFracBase = 0.30;

  int? _selectedReportId;
  int? _selectedEventId;

  List<MyReport> _myReports = [];
  bool _myLoading = false;
  String? _myError;

  bool _nearbyMenu = false;
  bool _gridMenu = false;
  bool _accidentMenu = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    await _initialLoad();
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
  }

  /// 알림에서 선택한 제보를 지도에서 열고 선택 상태 표시
  Future<void> _openReportById(int reportId) async {
    if (!mounted) return;

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
    _viewportDebounce?.cancel();
    _nearbyAlertTimer?.cancel();
    _openReportSub?.cancel();
    _openAccidentSub?.cancel();
    _posSub?.cancel();
    _searchCtrl.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _scheduleNearbyReportCheck(LatLng me, {bool force = false}) {
    if (!mounted) return;
    // 감시 ON이면 NearbyMonitor 가 전담 (중복 FGS·검사 방지)
    if (context.read<NearbyMonitor>().enabled) return;
    unawaited(
      context.read<NearbyReportAlert>().checkNear(me, force: force),
    );
  }

  /// 위험구간 ON/OFF + (ON 시) GPS 기준 즉시 알림 검사
  void _toggleAccidentZonesUi() {
    context.read<MapProvider>().toggleAccidentZones();
    final me = _myPos;
    if (me != null) {
      unawaited(
        context.read<NearbyReportAlert>().checkNear(me, force: true),
      );
    }
  }

  Future<void> _toggleNearbyMonitor() async {
    final monitor = context.read<NearbyMonitor>();
    final wasOn = monitor.enabled;
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

  Future<void> _initialLoad() async {
    if (_booted) return;
    _booted = true;

    // 기본값: 서울 → 가능하면 GPS로 교체
    var c = coerceLatLng(
      context.read<MapProvider>().center.latitude,
      context.read<MapProvider>().center.longitude,
    );
    var z = 14.0;

    final hasLocation =
        await _ensureLocationPermission(request: true);
    if (hasLocation && mounted) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
        final p = tryLatLng(pos.latitude, pos.longitude);
        if (p != null) {
          c = p;
          z = 15;
          if (mounted) setState(() => _myPos = p);
          _scheduleNearbyReportCheck(p, force: true);
        }
      } catch (_) {
        // 타임아웃·실패 시 기본 중심 유지
      }
      // 실시간 마커 갱신
      await _tryStartLocationTracking(requestPermission: false);
    }

    if (!mounted) return;
    context.read<MapProvider>().setCenter(c);
    context.read<MapProvider>().setZoom(z);
    _safeMapMove(c, z);
    await _loadAround(c, z);
  }

  Future<void> _loadAround(LatLng center, double zoom) async {
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

  /// GPS 스트림 — 마커를 위치에 따라 갱신 (지도 자동 추적은 버튼 탭 시만)
  Future<void> _tryStartLocationTracking({
    required bool requestPermission,
  }) async {
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
        if (p != null && mounted) setState(() => _myPos = p);
      } catch (_) {}
    }

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // 5m 이상 이동 시 갱신
    );
    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen((
      pos,
    ) {
      final p = tryLatLng(pos.latitude, pos.longitude);
      if (p == null || !mounted) return;
      setState(() => _myPos = p);
      _scheduleNearbyReportCheck(p);
    }, onError: (_) {});

    // 서 있을 때도 주기적으로 새 제보 검사
    _nearbyAlertTimer?.cancel();
    _nearbyAlertTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      final p = _myPos;
      if (p == null || !mounted) return;
      _scheduleNearbyReportCheck(p, force: true);
    });

    if (_myPos != null) {
      _scheduleNearbyReportCheck(_myPos!, force: true);
    }
  }

  Future<void> _myLocation() async {
    await _tryStartLocationTracking(requestPermission: true);
    if (!mounted) return;
    final latLng = _myPos;
    if (latLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('위치를 가져오지 못했습니다')),
      );
      return;
    }
    _safeMapMove(latLng, 15);
    await _loadAround(latLng, 15);
  }

  Future<void> _runSearch() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final mp = context.read<MapProvider>();
    final point = await mp.searchPlace(q);
    if (!mounted) return;
    setState(() => _searching = false);
    if (point == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('검색 결과가 없습니다')),
      );
      return;
    }
    _safeMapMove(point, 14);
    await _loadAround(point, 14);
  }

  Future<void> _loadMyReports() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      setState(() {
        _myReports = [];
        _myError = '로그인 후 이용할 수 있습니다';
      });
      return;
    }
    setState(() {
      _myLoading = true;
      _myError = null;
    });
    try {
      final list =
          await context.read<MyPageRepository>().fetchReports(limit: 30);
      if (!mounted) return;
      setState(() {
        _myReports = list;
        _myLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _myError = e.message;
        _myLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _myError = e.toString();
        _myLoading = false;
      });
    }
  }

  bool get _panelExpanded =>
      (_panelHeightPx ?? _collapsedBarH) > _collapsedBarH + 8;

  double _maxPanelHeight(double screenH) =>
      (screenH * 0.65).clamp(280.0, screenH * 0.75);

  /// 카드 선택 등에 맞춘 기본 펼침 높이 (탭·드래그 끝 스냅용)
  double _defaultOpenHeight(double screenH, MapProvider map) {
    const headerH = 52.0;
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
      case MapPanelTab.myReport:
        break;
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
    final open = _defaultOpenHeight(screenH, map);
    // 드래그 중만 중간 높이 미리보기, 아니면 접힘/펼침 두 단
    if (_panelDragging) {
      final h = _panelHeightPx ?? _collapsedBarH;
      return h.clamp(_collapsedBarH, open);
    }
    if (!_panelExpanded) return _collapsedBarH;
    return open;
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
    final same = _panelTab == tab;
    final wasOpen = _panelExpanded;
    setState(() => _panelTab = tab);
    if (tab == MapPanelTab.myReport) _loadMyReports();
    if (same && wasOpen) {
      _collapsePanel();
    } else {
      _expandPanel();
    }
  }

  void _onPanelDragUpdate(
    DragUpdateDetails details,
    double screenH,
    MapProvider map,
  ) {
    final open = _defaultOpenHeight(screenH, map);
    final cur = _panelHeightPx ??
        (_panelExpanded ? open : _collapsedBarH);
    // 위로 드래그(dy < 0) → 확대. 높이는 접힘~기본 펼침 사이만
    _setPanelHeight(cur - details.delta.dy, openH: open, drag: true);
  }

  void _onPanelDragEnd(
    DragEndDetails details,
    double screenH,
    MapProvider map,
  ) {
    final open = _defaultOpenHeight(screenH, map);
    final cur = _panelHeightPx ?? _collapsedBarH;
    final v = details.primaryVelocity ?? 0;
    final mid = (_collapsedBarH + open) / 2;

    // 중간 유지 없음 — 접힘 또는 기본 펼침만
    final bool expand;
    if (v > 700) {
      expand = false; // 아래로 플링
    } else if (v < -700) {
      expand = true; // 위로 플링
    } else {
      expand = cur >= mid; // 절반 넘기면 펼침
    }

    setState(() {
      _panelDragging = false;
      _panelHeightPx = expand ? open : _collapsedBarH;
    });
  }

  Future<void> _onGridTap(int gridId) async {
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
    final freeH = (screenH - panelH - railH).clamp(120.0, screenH);

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
    final useOffset =
        off != Offset.zero && _mapLayoutReady() && _cameraHealthy();
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

  @override
  Widget build(BuildContext context) {
    final map = context.watch<MapProvider>();
    final auth = context.watch<AuthProvider>();
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final screenH = MediaQuery.sizeOf(context).height;
    final railH = 56.0 + bottomPad;
    final panelH = _resolvePanelHeight(screenH, map);

    final allowPop = context.canPop();

    return PopScope(
      canPop: allowPop,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('앱 종료', textAlign: TextAlign.center,),
            content: const Text('앱을 종료할까요?', textAlign: TextAlign.center,),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('취소'),
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
                          point: _myPos!,
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          child: const _MyLocationDot(),
                        ),
                    ],
                  ),
                ],
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _searchCtrl,
                                      style: const TextStyle(
                                        color: Color(0xFF0F172A),
                                        fontSize: 15,
                                      ),
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      filled: false,
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 10,
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
                            if (auth.isLoggedIn) {
                              context.push('/mypage');
                            } else {
                              context.push('/login');
                            }
                          },
                          icon: Icon(
                            auth.isLoggedIn ? Icons.person : Icons.login,
                            color: MapUiColors.accent,
                          ),
                        ),
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

            // 하단 패널 (핸들 드래그로 높이 조절 · 탭 공통)
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
                child: _PanelBody(
                  tab: _panelTab,
                  expanded: _panelExpanded,
                  map: map,
                  selectedReportId: _selectedReportId,
                  selectedEventId: _selectedEventId,
                  myReports: _myReports,
                  myLoading: _myLoading,
                  myError: _myError,
                  onSelectReport: (r) => _selectReport(r, moveMap: true),
                  onSelectEvent: (e) => _selectEvent(e, moveMap: true),
                  onSelectMyReport: (r) {
                    // 지도 목록에 동일 id가 있으면 마커·말풍선까지 동기화
                    final id = r.id is int
                        ? r.id as int
                        : int.tryParse('${r.id}');
                    if (id != null) {
                      for (final item in map.reports) {
                        if (item.id == id) {
                          _selectReport(item, moveMap: true);
                          return;
                        }
                      }
                    }
                  }
                  final p = tryLatLng(r.lat, r.lng);
                  if (p != null) {
                    _focusMapOn(p, zoom: 16);
                    _loadAround(p, 16);
                  }
                },
                formatRange: _formatRange,
                onDragUpdate: (d) => _onPanelDragUpdate(d, screenH, map),
                onDragEnd: (d) => _onPanelDragEnd(d, screenH, map),
              ),
            ),
          ),

            // 제보 FAB — 패널 우측 위, 패널 높이에 따라 함께 상승
            AnimatedPositioned(
              duration: _panelDragging
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              right: 12,
              bottom: railH + panelH + 10,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(28),
                onTap: () {
                  if (!auth.isLoggedIn) {
                    context.push('/login');
                    return;
                  }
                  context.push('/report/create', extra: _myPos);
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.add_location_alt,
                        color: Color(0xFF0F172A),
                        size: 20,
                      ),
                      SizedBox(width: 6),
                      Text(
                        '제보',
                        style: TextStyle(
                          color: Color(0xFF0F172A),
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
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
                          icon: Icons.grid_on,
                          label: '격자',
                          selected: _panelTab == MapPanelTab.grid,
                          onTap: () => _openPanel(MapPanelTab.grid),
                        ),
                        _RailTab(
                          icon: Icons.radio_button_checked,
                          label: '행사',
                          selected: _panelTab == MapPanelTab.event,
                          onTap: () => _openPanel(MapPanelTab.event),
                        ),
                        _RailTab(
                          icon: Icons.priority_high,
                          label: '제보',
                          selected: _panelTab == MapPanelTab.report,
                          onTap: () => _openPanel(MapPanelTab.report),
                        ),
                        _RailTab(
                          icon: Icons.person_outline,
                          label: '내 제보',
                          selected: _panelTab == MapPanelTab.myReport,
                          onTap: () => _openPanel(MapPanelTab.myReport),
                    ),
                  ],
                ),
              ),
          ),
        ),
            ),
          ),
        ],
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

  IconData _infraIcon(String? type) {
    switch (type) {
      case 'CCTV':
        return Icons.videocam;
      case '경찰서':
        return Icons.local_police;
      case '소방서':
        return Icons.local_fire_department;
      case '편의점':
        return Icons.store;
      default:
        return Icons.place;
    }
  }
}

// --- UI bits ---

class _TopChip extends StatelessWidget {
  const _TopChip({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.icon,
    this.onLongPress,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final IconData? icon;

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
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? _bgOn : Colors.white,
            borderRadius: BorderRadius.circular(8),
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
                  if (icon != null) ...[
                    Icon(icon),
                    const SizedBox(width: 4),
                  ],
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
  const _MyLocationDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: MapUiColors.accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: MapUiColors.accent.withValues(alpha: 0.35),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }
}

class _RailTab extends StatelessWidget {
  const _RailTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  static const _idle = Color(0xFF0F172A);
  static const _active = Color(0xFF2563EB);

  @override
  Widget build(BuildContext context) {
    final color = selected ? _active : _idle;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 22),
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
    required this.myReports,
    required this.myLoading,
    required this.myError,
    required this.onSelectReport,
    required this.onSelectEvent,
    required this.onSelectMyReport,
    required this.formatRange,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final MapPanelTab tab;
  final bool expanded;
  final MapProvider map;
  final int? selectedReportId;
  final int? selectedEventId;
  final List<MyReport> myReports;
  final bool myLoading;
  final String? myError;
  final void Function(ReportItem) onSelectReport;
  final void Function(CityEventItem) onSelectEvent;
  final void Function(MyReport) onSelectMyReport;
  final String Function(String?, String?) formatRange;
  final void Function(DragUpdateDetails) onDragUpdate;
  final void Function(DragEndDetails) onDragEnd;

  String get _title => switch (tab) {
        MapPanelTab.grid => '격자 정보',
        MapPanelTab.event => '행사 · 도시정보',
        MapPanelTab.report => '제보',
        MapPanelTab.myReport => '내 제보',
      };

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 10,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // 핸들: 드래그로만 높이 조절 (탭 토글 없음)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: onDragUpdate,
            onVerticalDragEnd: onDragEnd,
            child: SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 40,
                            height: 5,
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF94A3B8),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          Text(
                            _title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
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
          ),
          if (expanded) ...[
            const Divider(height: 1),
            Expanded(child: _buildContent(context)),
          ],
        ],
      ),
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
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 12),
          itemCount: reports.length,
          itemBuilder: (_, i) {
            final r = reports[i];
            final nick = r.userNickname ?? '';
            final meta = [
              if (nick.isNotEmpty) nick,
              formatRange(r.createdAt, r.expireAt),
            ].join(' · ');
            return ReportListCard(
              type: r.type ?? '제보',
              description: r.description ?? '',
              meta: meta,
              selected: selectedReportId == r.id,
              onTap: () => onSelectReport(r),
            );
          },
        );
      case MapPanelTab.myReport:
        if (myLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (myError != null) {
          return Center(child: Text(myError!));
        }
        if (myReports.isEmpty) {
          return const Center(child: Text('내 제보가 없습니다'));
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 12),
          itemCount: myReports.length,
          itemBuilder: (_, i) {
            final r = myReports[i];
            return ReportListCard(
              type: r.type ?? '제보',
              description: r.description ?? '',
              meta: r.createdAt?.split('T').first,
              onTap: () => onSelectMyReport(r),
            );
          },
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
              _gradeLine(grade),
              const SizedBox(height: 8),
              Text(
                '안전등급: $grade · 인프라 ${d.infraCount ?? 0}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF334155)),
              ),
              const SizedBox(height: 6),
              Text(
                'CCTV ${stats['CCTV'] ?? 0} · 경찰서 ${stats['경찰서'] ?? 0} · '
                '소방서 ${stats['소방서'] ?? 0} · 편의점 ${stats['편의점'] ?? 0}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
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
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '[${r['type'] ?? '제보'}] ${r['description'] ?? ''}',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF334155)),
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
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 64,
                          child: Text(t.name, style: const TextStyle(fontSize: 12)),
                        ),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: (t.count / max).clamp(0.05, 1),
                              minHeight: 8,
                              backgroundColor: const Color(0xFFE2E8F0),
                              color: const Color(0xFFA5F3FC),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${t.count}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF0E7490),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
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
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      line.isEmpty ? '피드백' : line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF334155),
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
