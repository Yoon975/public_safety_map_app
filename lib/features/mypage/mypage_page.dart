import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/config/media_url.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/user_error.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/models.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/feedback_repository.dart';
import '../../data/repositories/mypage_repository.dart';
import '../../data/repositories/report_repository.dart';
import '../../providers/auth_provider.dart';
import '../../providers/fcm_inbox_store.dart';
import '../../providers/map_provider.dart';
import '../../services/nearby_monitor.dart';
import '../../services/nearby_report_alert.dart';
import '../../services/device_notification_permission.dart';
import '../../widgets/media_image.dart';
import '../../core/geo/geo_utils.dart';
import '../report/create_report_page.dart';

const _kText = Color(0xFF0F172A);
const _kMuted = Color(0xFF64748B);
const _kBorder = Color(0xFFE2E8F0);
const _kFieldFill = Color(0xFFF1F5F9);

Future<bool> _confirmDeleteDialog({
  required BuildContext context,
  required String title,
  required String message,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: _kText,
        ),
      ),
      content: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15, color: _kMuted, height: 1.4),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('취소', style: TextStyle(color: _kMuted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: MapUiColors.report,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('삭제'),
        ),
      ],
    ),
  );
  return ok == true;
}

InputDecoration _sheetFieldDecoration({required String label}) {
  return InputDecoration(
    labelText: label,
    alignLabelWithHint: true,
    labelStyle: const TextStyle(color: _kMuted, fontSize: 14),
    filled: true,
    fillColor: _kFieldFill,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: MapUiColors.accent, width: 1.5),
    ),
  );
}

ButtonStyle _sheetOutlineStyle() {
  return OutlinedButton.styleFrom(
    foregroundColor: _kText,
    side: const BorderSide(color: Color(0xFFCBD5E1)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    padding: const EdgeInsets.symmetric(vertical: 14),
  );
}

ButtonStyle _sheetFilledStyle({Color background = MapUiColors.accent}) {
  return FilledButton.styleFrom(
    backgroundColor: background,
    foregroundColor: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    padding: const EdgeInsets.symmetric(vertical: 14),
  );
}

const _safetyFeelings = ['안전', '보통', '불안'];

class _SheetLabeled extends StatelessWidget {
  const _SheetLabeled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: _kMuted,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

int? _toIntId(Object? id) {
  if (id is int) return id;
  if (id == null) return null;
  return int.tryParse('$id');
}

class MyPage extends StatefulWidget {
  const MyPage({super.key});

  @override
  State<MyPage> createState() => _MyPageState();
}

enum _MyPageSection { menu, reports, feedbacks, notifications }

class _MyPageState extends State<MyPage> {
  static const _pageSize = 10;

  _MyPageSection _section = _MyPageSection.menu;
  MyPageSummary? summary;
  List<MyReport> reports = [];
  List<MyFeedback> feedbacks = [];
  bool loading = true;
  String? error;

  int _reportPage = 1;
  int _feedbackPage = 1;
  bool _reportsHasMore = true;
  bool _feedbacksHasMore = true;
  bool _reportsLoadingMore = false;
  bool _feedbacksLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool tryReopen = true}) async {
    final repo = context.read<MyPageRepository>();
    setState(() {
      loading = true;
      error = null;
      _reportPage = 1;
      _feedbackPage = 1;
      _reportsHasMore = true;
      _feedbacksHasMore = true;
      _reportsLoadingMore = false;
      _feedbacksLoadingMore = false;
    });
    try {
      final s = await repo.fetchSummary();
      final r = await repo.fetchReports(page: 1, limit: _pageSize);
      final f = await repo.fetchFeedbacks(page: 1, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        summary = s;
        reports = r;
        feedbacks = f;
        _reportsHasMore = r.length >= _pageSize;
        _feedbacksHasMore = f.length >= _pageSize;
        loading = false;
      });
      if (tryReopen) await _maybeReopenPendingDetail();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        error = userFacingError(e);
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = userFacingError(e);
        loading = false;
      });
    }
  }

  Future<void> _loadMoreReports() async {
    if (_reportsLoadingMore || !_reportsHasMore || loading) return;
    final repo = context.read<MyPageRepository>();
    setState(() => _reportsLoadingMore = true);
    try {
      final next = _reportPage + 1;
      final chunk = await repo.fetchReports(page: next, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        reports = [...reports, ...chunk];
        _reportPage = next;
        _reportsHasMore = chunk.length >= _pageSize;
        _reportsLoadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _reportsLoadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _reportsLoadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    }
  }

  Future<void> _loadMoreFeedbacks() async {
    if (_feedbacksLoadingMore || !_feedbacksHasMore || loading) return;
    final repo = context.read<MyPageRepository>();
    setState(() => _feedbacksLoadingMore = true);
    try {
      final next = _feedbackPage + 1;
      final chunk = await repo.fetchFeedbacks(page: next, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        feedbacks = [...feedbacks, ...chunk];
        _feedbackPage = next;
        _feedbacksHasMore = chunk.length >= _pageSize;
        _feedbacksLoadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _feedbacksLoadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _feedbacksLoadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    }
  }

  /// 지도에서 위치 확인 후 마이페이지로 다시 들어오면 보던 상세 복원
  Future<void> _maybeReopenPendingDetail() async {
    if (!mounted) return;
    final pending = context.read<MapProvider>().takePendingMypageReopen();
    if (pending == null) return;

    final reportId = pending.reportId;
    if (reportId != null) {
      MyReport? found;
      for (final r in reports) {
        if (_toIntId(r.id) == reportId) {
          found = r;
          break;
        }
      }
      if (found == null) return;
      setState(() => _section = _MyPageSection.reports);
      await _openReportDetail(found);
      return;
    }

    final feedbackId = pending.feedbackId;
    if (feedbackId != null) {
      MyFeedback? found;
      for (final f in feedbacks) {
        if (f.id == feedbackId) {
          found = f;
          break;
        }
      }
      if (found == null) return;
      setState(() => _section = _MyPageSection.feedbacks);
      await _openFeedbackDetail(found);
      return;
    }

    if (pending.notifications) {
      setState(() => _section = _MyPageSection.notifications);
    }
  }

  Future<void> _openNotificationLocation(AppNotification item) async {
    await context.read<FcmInboxStore>().markRead(item.id);
    if (!mounted) return;
    final p = tryLatLng(item.lat, item.lng);
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('위치 정보가 없습니다')),
      );
      return;
    }
    final map = context.read<MapProvider>();
    map.setPendingMypageReopen(notifications: true);
    map.requestMapFocus(
      MapFocusTarget(
        lat: p.latitude,
        lng: p.longitude,
        reportId: item.reportId,
        gridId: item.gridId,
      ),
    );
    context.pop();
  }

  Future<void> _deleteAllNotifications() async {
    final inbox = context.read<FcmInboxStore>();
    if (inbox.items.isEmpty) return;
    final ok = await _confirmDeleteDialog(
      context: context,
      title: '알림 전체 삭제',
      message: '받은 알림을 모두 삭제할까요?',
    );
    if (!ok || !mounted) return;
    await inbox.clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('알림을 모두 삭제했습니다')),
    );
  }

  Future<void> _openReportDetail(MyReport r) async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ReportDetailSheet(report: r),
    );
    if (!mounted) return;
    if (result == true) {
      await _load(tryReopen: false);
      return;
    }
    if (result is MapFocusTarget) {
      final map = context.read<MapProvider>();
      map.setPendingMypageReopen(reportId: _toIntId(r.id));
      map.requestMapFocus(result);
      context.pop();
    }
  }

  Future<void> _openFeedbackDetail(MyFeedback f) async {
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _FeedbackDetailSheet(feedback: f),
    );
    if (!mounted) return;
    if (result == true) {
      await _load(tryReopen: false);
      return;
    }
    if (result is MapFocusTarget) {
      final map = context.read<MapProvider>();
      map.setPendingMypageReopen(feedbackId: f.id > 0 ? f.id : null);
      map.requestMapFocus(result);
      context.pop();
    }
  }

  InputDecoration _passwordFieldDecoration({
    required String hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 15),
      filled: true,
      fillColor: const Color(0xFFF1F5F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: MapUiColors.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: MapUiColors.report),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: MapUiColors.report, width: 1.5),
      ),
      suffixIcon: suffixIcon,
    );
  }

  Widget _visibilityToggle({
    required bool obscure,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(
        obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        color: const Color(0xFF94A3B8),
      ),
    );
  }

  Future<void> _changePassword() async {
    final email = context.read<AuthProvider>().user?.email ?? '';
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var obscureCurrent = true;
    var obscureNext = true;
    var obscureConfirm = true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text(
            '비밀번호 변경',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: current,
                  obscureText: obscureCurrent,
                  textInputAction: TextInputAction.next,
                  decoration: _passwordFieldDecoration(
                    hint: '현재 비밀번호',
                    suffixIcon: _visibilityToggle(
                      obscure: obscureCurrent,
                      onPressed: () => setDialogState(
                        () => obscureCurrent = !obscureCurrent,
                      ),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? '현재 비밀번호를 입력하세요' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: next,
                  obscureText: obscureNext,
                  textInputAction: TextInputAction.next,
                  decoration: _passwordFieldDecoration(
                    hint: '새 비밀번호',
                    suffixIcon: _visibilityToggle(
                      obscure: obscureNext,
                      onPressed: () =>
                          setDialogState(() => obscureNext = !obscureNext),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) return '새 비밀번호를 입력하세요';
                    if (v.length < 6) return '6자 이상 입력하세요';
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: confirm,
                  obscureText: obscureConfirm,
                  textInputAction: TextInputAction.done,
                  decoration: _passwordFieldDecoration(
                    hint: '새 비밀번호 확인',
                    suffixIcon: _visibilityToggle(
                      obscure: obscureConfirm,
                      onPressed: () => setDialogState(
                        () => obscureConfirm = !obscureConfirm,
                      ),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.isEmpty) {
                      return '새 비밀번호를 다시 입력하세요';
                    }
                    if (v != next.text) return '비밀번호가 일치하지 않습니다';
                    return null;
                  },
                  onFieldSubmitted: (_) {
                    if (formKey.currentState?.validate() ?? false) {
                      Navigator.pop(ctx, true);
                    }
                  },
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(ctx, true);
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: MapUiColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text('변경'),
            ),
          ],
        ),
      ),
    );

    final currentPw = current.text;
    final nextPw = next.text;
    current.dispose();
    next.dispose();
    confirm.dispose();

    if (ok != true || !mounted) return;
    try {
      await context.read<AuthRepository>().changePassword(
        email: email,
        password: currentPw,
        newPassword: nextPw,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('비밀번호가 변경되었습니다')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
    }
  }

  String get _title => switch (_section) {
        _MyPageSection.menu => '마이페이지',
        _MyPageSection.reports => '내 제보',
        _MyPageSection.feedbacks => '내 피드백',
        _MyPageSection.notifications => '알림 목록',
      };

  Future<void> _logout() async {
    final auth = context.read<AuthProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('로그아웃', textAlign: TextAlign.center),
        content: const Text('로그아웃 하시겠습니까?', textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('로그아웃', textAlign: TextAlign.center),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await auth.logout();
    if (!mounted) return;
    context.go('/map');
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final inbox = context.watch<FcmInboxStore>();
    final onMenu = _section == _MyPageSection.menu;

    return PopScope(
      canPop: onMenu,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || onMenu) return;
        setState(() => _section = _MyPageSection.menu);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          leading: onMenu
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () =>
                      setState(() => _section = _MyPageSection.menu),
                ),
          actions: [
            if (onMenu)
              IconButton(
                tooltip: '로그아웃',
                onPressed: _logout,
                icon: const Icon(Icons.logout),
              ),
            if (_section == _MyPageSection.notifications)
              IconButton(
                tooltip: '알림 전체 삭제',
                onPressed: inbox.items.isEmpty ? null : _deleteAllNotifications,
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(error!),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('다시 시도'),
                        ),
                      ],
                    ),
                  )
                : switch (_section) {
                    _MyPageSection.menu => _MenuBody(
                        nickname: auth.user?.nickname ?? '사용자',
                        email: auth.user?.email ?? '',
                        reportCount: summary?.reportCount ?? 0,
                        feedbackCount: summary?.feedbackCount ?? 0,
                        unreadNotificationCount: inbox.unreadCount,
                        onReports: () =>
                            setState(() => _section = _MyPageSection.reports),
                        onFeedbacks: () => setState(
                          () => _section = _MyPageSection.feedbacks,
                        ),
                        onNotifications: () => setState(
                          () => _section = _MyPageSection.notifications,
                        ),
                        onChangePassword: _changePassword,
                      ),
                    _MyPageSection.reports => _ReportList(
                        reports: reports,
                        loadingMore: _reportsLoadingMore,
                        hasMore: _reportsHasMore,
                        onLoadMore: _loadMoreReports,
                        onTap: _openReportDetail,
                      ),
                    _MyPageSection.feedbacks => _FeedbackList(
                        feedbacks: feedbacks,
                        loadingMore: _feedbacksLoadingMore,
                        hasMore: _feedbacksHasMore,
                        onLoadMore: _loadMoreFeedbacks,
                        onTap: _openFeedbackDetail,
                      ),
                    _MyPageSection.notifications => _NotificationList(
                        notifications: inbox.items,
                        onTap: inbox.markRead,
                        onCheckLocation: _openNotificationLocation,
                      ),
                  },
      ),
    );
  }
}

class _MenuBody extends StatelessWidget {
  const _MenuBody({
    required this.nickname,
    required this.email,
    required this.reportCount,
    required this.feedbackCount,
    required this.unreadNotificationCount,
    required this.onReports,
    required this.onFeedbacks,
    required this.onNotifications,
    required this.onChangePassword,
  });

  final String nickname;
  final String email;
  final int reportCount;
  final int feedbackCount;
  final int unreadNotificationCount;
  final VoidCallback onReports;
  final VoidCallback onFeedbacks;
  final VoidCallback onNotifications;
  final VoidCallback onChangePassword;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: MapUiColors.accentSoft,
                child: Text(
                  nickname.isNotEmpty ? nickname.characters.first : '?',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: MapUiColors.accent,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nickname,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      email.isEmpty ? '이메일 없음' : email,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _MenuCard(
          children: [
            _MenuTile(
              label: '내 제보',
              subtitle: '$reportCount건',
              onTap: onReports,
            ),
            _MenuTile(
              label: '내 피드백',
              subtitle: '$feedbackCount건',
              onTap: onFeedbacks,
            ),
            _MenuTile(
              icon: Icons.notifications_outlined,
              label: '알림 목록',
              subtitle: unreadNotificationCount > 0
                  ? '미확인 $unreadNotificationCount건'
                  : null,
              onTap: onNotifications,
              showDivider: false,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _MenuCard(
          title: '인증 및 보안',
          children: [
            _MenuTile(
              label: '비밀번호 변경',
              onTap: onChangePassword,
              showDivider: false,
            ),
          ],
        ),
        const SizedBox(height: 12),
        const _SettingsCard(),
      ],
    );
  }
}

class _SettingsCard extends StatefulWidget {
  const _SettingsCard();

  @override
  State<_SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends State<_SettingsCard> {
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    NearbyReportAlert.isGlobalNotificationsEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  void _toggle(bool value) async {
    if (value) {
      final ok = await ensureDeviceNotificationPermission(context);
      if (!mounted) return;
      if (!ok) {
        setState(() => _enabled = false);
        return;
      }
      setState(() => _enabled = true);
      await NearbyReportAlert.setGlobalNotificationsEnabled(true);
      return;
    }

    setState(() => _enabled = false);
    await NearbyReportAlert.setGlobalNotificationsEnabled(false);
    if (!mounted) return;
    await context.read<NearbyMonitor>().stop();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              '설정',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.notifications_outlined,
                    size: 22, color: MapUiColors.accent),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '알림 설정',
                    style: TextStyle(fontSize: 15, color: Color(0xFF0F172A)),
                  ),
                ),
                Switch.adaptive(
                  value: _enabled,
                  onChanged: _toggle,
                  activeTrackColor: MapUiColors.accent,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(
                title!,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.label,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.showDivider = true,
  });

  final IconData? icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 22, color: MapUiColors.accent),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: MapUiColors.accent,
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right,
                  color: Color(0xFF94A3B8),
                ),
              ],
            ),
          ),
        ),
        if (showDivider)
          const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}

class _ReportList extends StatefulWidget {
  const _ReportList({
    required this.reports,
    required this.loadingMore,
    required this.hasMore,
    required this.onLoadMore,
    required this.onTap,
  });

  final List<MyReport> reports;
  final bool loadingMore;
  final bool hasMore;
  final Future<void> Function() onLoadMore;
  final void Function(MyReport) onTap;

  @override
  State<_ReportList> createState() => _ReportListState();
}

class _ReportListState extends State<_ReportList> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMoreIfShort());
  }

  @override
  void didUpdateWidget(covariant _ReportList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reports.length != oldWidget.reports.length ||
        widget.loadingMore != oldWidget.loadingMore ||
        widget.hasMore != oldWidget.hasMore) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybeLoadMoreIfShort());
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    if (_controller.position.pixels <
        _controller.position.maxScrollExtent - 200) {
      return;
    }
    if (!widget.hasMore || widget.loadingMore) return;
    widget.onLoadMore();
  }

  /// 화면을 다 채우지 못해 스크롤이 안 되면 다음 페이지를 이어서 로드
  void _maybeLoadMoreIfShort() {
    if (!mounted || !_controller.hasClients) return;
    if (!widget.hasMore || widget.loadingMore) return;
    if (_controller.position.maxScrollExtent <= 0) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reports.isEmpty && !widget.loadingMore) {
      return const _EmptyListHint(message: '제보가 없습니다');
    }
    return ListView.separated(
      controller: _controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: widget.reports.length + (widget.loadingMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        if (i >= widget.reports.length) {
          return const _ListLoadingFooter();
        }
        final r = widget.reports[i];
        final desc = (r.description ?? '').trim();
        return _ContentCard(
          title: '[${r.type ?? '제보'}] $desc',
          meta: _formatDateTime(r.createdAt),
          onTap: () => widget.onTap(r),
        );
      },
    );
  }
}

class _FeedbackList extends StatefulWidget {
  const _FeedbackList({
    required this.feedbacks,
    required this.loadingMore,
    required this.hasMore,
    required this.onLoadMore,
    required this.onTap,
  });

  final List<MyFeedback> feedbacks;
  final bool loadingMore;
  final bool hasMore;
  final Future<void> Function() onLoadMore;
  final void Function(MyFeedback) onTap;

  @override
  State<_FeedbackList> createState() => _FeedbackListState();
}

class _FeedbackListState extends State<_FeedbackList> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMoreIfShort());
  }

  @override
  void didUpdateWidget(covariant _FeedbackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.feedbacks.length != oldWidget.feedbacks.length ||
        widget.loadingMore != oldWidget.loadingMore ||
        widget.hasMore != oldWidget.hasMore) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybeLoadMoreIfShort());
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    if (_controller.position.pixels <
        _controller.position.maxScrollExtent - 200) {
      return;
    }
    if (!widget.hasMore || widget.loadingMore) return;
    widget.onLoadMore();
  }

  void _maybeLoadMoreIfShort() {
    if (!mounted || !_controller.hasClients) return;
    if (!widget.hasMore || widget.loadingMore) return;
    if (_controller.position.maxScrollExtent <= 0) {
      widget.onLoadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.feedbacks.isEmpty && !widget.loadingMore) {
      return const _EmptyListHint(
        message: '피드백이 없습니다\n지도에서 격자를 선택해 작성할 수 있습니다',
      );
    }
    return ListView.separated(
      controller: _controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: widget.feedbacks.length + (widget.loadingMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        if (i >= widget.feedbacks.length) {
          return const _ListLoadingFooter();
        }
        final f = widget.feedbacks[i];
        final body = (f.comment?.isNotEmpty == true)
            ? f.comment!
            : f.tags.join(', ');
        return _ContentCard(
          title: '[${f.safetyFeeling ?? '피드백'}] $body',
          meta: _formatDateTime(f.createdAt),
          onTap: () => widget.onTap(f),
        );
      },
    );
  }
}

class _NotificationList extends StatelessWidget {
  const _NotificationList({
    required this.notifications,
    required this.onTap,
    required this.onCheckLocation,
  });

  final List<AppNotification> notifications;
  final Future<void> Function(String id) onTap;
  final Future<void> Function(AppNotification) onCheckLocation;

  @override
  Widget build(BuildContext context) {
    if (notifications.isEmpty) {
      return const _EmptyListHint(message: '받은 알림이 없습니다');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: notifications.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final n = notifications[i];
        final date = n.createdAt?.replaceFirst('T', ' ') ?? '';
        final dateShort = date.length >= 16 ? date.substring(0, 16) : date;
        return _NotificationCard(
          notification: n,
          meta: dateShort.isEmpty ? null : dateShort,
          onTap: () => onTap(n.id),
          onCheckLocation: () => onCheckLocation(n),
        );
      },
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.onTap,
    required this.onCheckLocation,
    this.meta,
  });

  final AppNotification notification;
  final String? meta;
  final VoidCallback onTap;
  final VoidCallback onCheckLocation;

  @override
  Widget build(BuildContext context) {
    final unread = !notification.isRead;
    return Material(
      color: unread ? const Color(0xFFEFF6FF) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: unread ? const Color(0xFFBFDBFE) : const Color(0xFFE2E8F0),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      notification.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                        color: _kText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: unread
                          ? MapUiColors.accent
                          : const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      unread ? '미확인' : '확인',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: unread ? Colors.white : _kMuted,
                      ),
                    ),
                  ),
                ],
              ),
              if (notification.body != null) ...[
                const SizedBox(height: 4),
                Text(
                  notification.body!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: _kMuted,
                  ),
                ),
              ],
              if (meta != null) ...[
                const SizedBox(height: 6),
                Text(
                  meta!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MapUiColors.accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              if (tryLatLng(notification.lat, notification.lng) != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kText,
                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onCheckLocation,
                    icon: const Icon(Icons.map_outlined, size: 16),
                    label: const Text('위치 확인'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ContentCard extends StatelessWidget {
  const _ContentCard({
    required this.title,
    required this.onTap,
    this.meta,
  });

  /// "[태그] 내용" 형태의 한 줄 요약
  final String title;
  /// 날짜-시간
  final String? meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    if (meta != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        meta!,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right,
                color: Color(0xFF94A3B8),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ISO8601 문자열 → "YYYY-MM-DD HH:mm" (날짜만 있던 자리에 시간까지 표시)
String? _formatDateTime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  final t = iso.replaceFirst('T', ' ');
  return t.length >= 16 ? t.substring(0, 16) : t;
}

class _EmptyListHint extends StatelessWidget {
  const _EmptyListHint({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              height: 1.45,
              color: Color(0xFF64748B),
            ),
          ),
        ),
      ),
    );
  }
}

class _ListLoadingFooter extends StatelessWidget {
  const _ListLoadingFooter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

// ─── 제보 상세 / 수정 / 삭제 ─────────────────────────────────────────

class _ReportDetailSheet extends StatefulWidget {
  const _ReportDetailSheet({required this.report});
  final MyReport report;

  @override
  State<_ReportDetailSheet> createState() => _ReportDetailSheetState();
}

class _ReportDetailSheetState extends State<_ReportDetailSheet> {
  late final TextEditingController _desc;
  late String _type;
  bool _editing = false;
  bool _busy = false;
  String? _localImagePath;
  bool _clearImage = false;
  late String? _currentImgUrl;

  List<String> get _typeOptions {
    if (_type.isEmpty || reportTypes.contains(_type)) return reportTypes;
    return [_type, ...reportTypes];
  }

  @override
  void initState() {
    super.initState();
    final t = widget.report.type?.trim();
    _type = (t != null && t.isNotEmpty) ? t : reportTypes.first;
    _desc = TextEditingController(text: widget.report.description ?? '');
    _currentImgUrl = widget.report.imgUrl;
  }

  @override
  void dispose() {
    _desc.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 70,
    );
    if (file != null) {
      setState(() {
        _localImagePath = file.path;
        _clearImage = false;
      });
    }
  }

  Future<void> _save() async {
    final id = _toIntId(widget.report.id);
    if (id == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('유효하지 않은 제보 ID입니다')));
      return;
    }
    final desc = _desc.text.trim();
    if (desc.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('설명을 입력해 주세요')));
      return;
    }

    setState(() => _busy = true);
    try {
      final repo = context.read<ReportRepository>();
      String? imgUrl;
      if (_localImagePath != null) {
        imgUrl = await repo.uploadReportImage(_localImagePath!);
        if (imgUrl.isEmpty) imgUrl = null;
      }
      await repo.updateReport(
        id,
        type: _type,
        description: desc,
        imgUrl: imgUrl,
        clearImage: _clearImage && _localImagePath == null,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, true);
      messenger.showSnackBar(const SnackBar(content: Text('제보가 수정되었습니다')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final id = _toIntId(widget.report.id);
    if (id == null) return;

    final ok = await _confirmDeleteDialog(
      context: context,
      title: '제보 삭제',
      message: '이 제보를 삭제할까요?',
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await context.read<ReportRepository>().deleteReport(id);
      if (!mounted) return;
      context.read<MapProvider>().removeReportById(id);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, true);
      messenger.showSnackBar(const SnackBar(content: Text('제보가 삭제되었습니다')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final mq = MediaQuery.of(context);
    final bottomPad = 24 + mq.viewPadding.bottom + mq.viewInsets.bottom;
    final created = _formatDateTime(r.createdAt) ?? '-';

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SheetLabeled(
                  label: '유형',
                  child: _editing
                      ? DropdownButtonFormField<String>(
                          // ignore: deprecated_member_use
                          value: _type,
                          items: _typeOptions
                              .map(
                                (t) => DropdownMenuItem(
                                  value: t,
                                  child: Text(t),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _type = v);
                          },
                          decoration: _sheetFieldDecoration(label: '유형')
                              .copyWith(labelText: null),
                          style: const TextStyle(
                            fontSize: 15,
                            color: _kText,
                          ),
                        )
                      : Text(
                          _type.isEmpty ? '제보' : _type,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _kText,
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                _SheetLabeled(
                  label: '작성일',
                  child: Text(
                    created,
                    style: const TextStyle(fontSize: 15, color: _kText),
                  ),
                ),
                const SizedBox(height: 16),
                _SheetLabeled(
                  label: '설명',
                  child: _editing
                      ? TextField(
                          controller: _desc,
                          maxLines: 5,
                          style: const TextStyle(fontSize: 15, color: _kText),
                          decoration: _sheetFieldDecoration(label: '설명')
                              .copyWith(
                            labelText: null,
                            hintText: '설명을 입력해 주세요',
                          ),
                        )
                      : Text(
                          (r.description ?? '').isEmpty
                              ? '(설명 없음)'
                              : r.description!,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.45,
                            color: _kText,
                          ),
                        ),
                ),
                if (_editing) ...[
                  const SizedBox(height: 16),
                  _ImageEditBlock(
                    remoteUrl: _clearImage ? null : _currentImgUrl,
                    localPath: _localImagePath,
                    onPick: _pickImage,
                    onClear: () => setState(() {
                      _localImagePath = null;
                      _clearImage = true;
                      _currentImgUrl = null;
                    }),
                  ),
                ] else if (resolveMediaUrl(_currentImgUrl) != null) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: MediaCoverImage(
                      url: _currentImgUrl,
                      expanded: true,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!_editing && !_busy) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: _sheetOutlineStyle(),
              onPressed: () {
                final p = tryLatLng(r.lat, r.lng);
                if (p == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('위치 정보가 없습니다')),
                  );
                  return;
                }
                Navigator.pop(
                  context,
                  MapFocusTarget(
                    lat: p.latitude,
                    lng: p.longitude,
                    reportId: _toIntId(r.id),
                  ),
                );
              },
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('제보 위치로 이동'),
            ),
          ],
          const SizedBox(height: 12),
          if (_busy)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_editing)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: _sheetOutlineStyle(),
                    onPressed: () {
                      setState(() {
                        _editing = false;
                        final t = r.type?.trim();
                        _type = (t != null && t.isNotEmpty)
                            ? t
                            : reportTypes.first;
                        _desc.text = r.description ?? '';
                        _localImagePath = null;
                        _clearImage = false;
                        _currentImgUrl = r.imgUrl;
                      });
                    },
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: _sheetFilledStyle(),
                    onPressed: _save,
                    child: const Text('저장'),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: _sheetOutlineStyle(),
                    onPressed: () => setState(() => _editing = true),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('수정'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: _sheetFilledStyle(background: MapUiColors.report),
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('삭제'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ─── 피드백 상세 / 수정 / 삭제 ───────────────────────────────────────

class _FeedbackDetailSheet extends StatefulWidget {
  const _FeedbackDetailSheet({required this.feedback});
  final MyFeedback feedback;

  @override
  State<_FeedbackDetailSheet> createState() => _FeedbackDetailSheetState();
}

class _FeedbackDetailSheetState extends State<_FeedbackDetailSheet> {
  late final TextEditingController _comment;
  late String _feeling;
  bool _editing = false;
  bool _busy = false;
  String? _localImagePath;
  bool _clearImage = false;
  late String? _currentImgUrl;
  List<FeedbackTag> _allTags = [];
  final Set<int> _selectedTagIds = {};
  bool _tagsLoading = true;

  @override
  void initState() {
    super.initState();
    final f = widget.feedback;
    _comment = TextEditingController(text: f.comment ?? '');
    _feeling = _safetyFeelings.contains(f.safetyFeeling)
        ? f.safetyFeeling!
        : _safetyFeelings[1];
    _currentImgUrl = f.imgUrl;
    _loadTags();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _loadTags() async {
  try {
    final list = await context.read<FeedbackRepository>().fetchTags();
    if (!mounted) return;
    final names = widget.feedback.tags.map((e) => e.trim()).toSet();
    setState(() {
      _allTags = list.where((t) => t.id > 0 && t.name.isNotEmpty).toList();
      _selectedTagIds
        ..clear()
        ..addAll(
          _allTags.where((t) => names.contains(t.name)).map((t) => t.id),
        );
      _tagsLoading = false;
    });
  } catch (_) {
    if (!mounted) return;
    setState(() {
      _allTags = [];
      _tagsLoading = false;
    });
  }
}

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 70,
    );
    if (file != null) {
      setState(() {
        _localImagePath = file.path;
        _clearImage = false;
      });
    }
  }

    Future<void> _save() async {
      final id = widget.feedback.id;
      if (id <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('유효하지 않은 피드백 ID입니다')),
        );
        return;
      }
    
    setState(() => _busy = true);
    try {
      final repo = context.read<FeedbackRepository>();
      String? imgUrl;
      if (_localImagePath != null) {
        imgUrl = await repo.uploadFeedbackImage(_localImagePath!);
        if (imgUrl.isEmpty) imgUrl = null;
      }
      await repo.updateFeedback(
        id,
        safetyFeeling: _feeling,
        comment: _comment.text.trim(),
        imgUrl: imgUrl,
        clearImage: _clearImage && _localImagePath == null,
        tagIds: _selectedTagIds.toList()..sort(),
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, true);
      messenger.showSnackBar(const SnackBar(content: Text('피드백이 수정되었습니다')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final id = widget.feedback.id;
    if (id <= 0) return;

    final ok = await _confirmDeleteDialog(
      context: context,
      title: '피드백 삭제',
      message: '이 피드백을 삭제할까요?',
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await context.read<FeedbackRepository>().deleteFeedback(id);
      if (!mounted) return;
      context.read<MapProvider>().removeFeedbackById(
            id,
            gridId: _toIntId(widget.feedback.gridId),
          );
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context, true);
      messenger.showSnackBar(const SnackBar(content: Text('피드백이 삭제되었습니다')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFacingError(e))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(userFacingError(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.feedback;
    final mq = MediaQuery.of(context);
    final bottomPad = 24 + mq.viewPadding.bottom + mq.viewInsets.bottom;
    final created = _formatDateTime(f.createdAt) ?? '-';

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SheetLabeled(
                  label: '안전감',
                  child: _editing
                      ? DropdownButtonFormField<String>(
                          // ignore: deprecated_member_use
                          value: _feeling,
                          items: _safetyFeelings
                              .map(
                                (e) => DropdownMenuItem(
                                  value: e,
                                  child: Text(e),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _feeling = v);
                          },
                          decoration: _sheetFieldDecoration(label: '안전감')
                              .copyWith(labelText: null),
                          style: const TextStyle(
                            fontSize: 15,
                            color: _kText,
                          ),
                        )
                      : Text(
                          f.safetyFeeling ?? '피드백',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _kText,
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                _SheetLabeled(
                  label: '작성일',
                  child: Text(
                    created,
                    style: const TextStyle(fontSize: 15, color: _kText),
                  ),
                ),
                const SizedBox(height: 16),
                _SheetLabeled(
                  label: '코멘트',
                  child: _editing
                      ? TextField(
                          controller: _comment,
                          maxLines: 5,
                          style: const TextStyle(fontSize: 15, color: _kText),
                          decoration: _sheetFieldDecoration(label: '코멘트')
                              .copyWith(
                            labelText: null,
                            hintText: '의견을 입력해 주세요',
                          ),
                        )
                      : Text(
                          (f.comment ?? '').isEmpty
                              ? '(코멘트 없음)'
                              : f.comment!,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.45,
                            color: _kText,
                          ),
                        ),
                ),
                if (_editing) ...[
                  const SizedBox(height: 16),
                  _SheetLabeled(
                    label: '태그',
                    child: _tagsLoading
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          )
                        : _allTags.isEmpty
                            ? const Text(
                                '등록된 태그가 없습니다',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: _kMuted,
                                ),
                              )
                            : Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: _allTags.map((t) {
                                  final selected =
                                      _selectedTagIds.contains(t.id);
                                  return FilterChip(
                                    label: Text(
                                      t.name,
                                      style: TextStyle(
                                        color: selected
                                            ? MapUiColors.accent
                                            : _kText,
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                    selected: selected,
                                    backgroundColor: Colors.white,
                                    selectedColor: MapUiColors.accentSoft,
                                    checkmarkColor: MapUiColors.accent,
                                    side: BorderSide(
                                      color: selected
                                          ? MapUiColors.accent
                                          : const Color(0xFFCBD5E1),
                                    ),
                                    onSelected: (v) {
                                      setState(() {
                                        if (v) {
                                          _selectedTagIds.add(t.id);
                                        } else {
                                          _selectedTagIds.remove(t.id);
                                        }
                                      });
                                    },
                                  );
                                }).toList(),
                              ),
                  ),
                  const SizedBox(height: 16),
                  _ImageEditBlock(
                    remoteUrl: _clearImage ? null : _currentImgUrl,
                    localPath: _localImagePath,
                    onPick: _pickImage,
                    onClear: () => setState(() {
                      _localImagePath = null;
                      _clearImage = true;
                      _currentImgUrl = null;
                    }),
                  ),
                ] else ...[
                  if (f.tags.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _SheetLabeled(
                      label: '태그',
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: f.tags
                            .map(
                              (t) => Chip(
                                label: Text(
                                  t,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: _kText,
                                  ),
                                ),
                                backgroundColor: Colors.white,
                                side: const BorderSide(
                                  color: Color(0xFFCBD5E1),
                                ),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                  if (resolveMediaUrl(_currentImgUrl) != null) ...[
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: MediaCoverImage(
                        url: _currentImgUrl,
                        expanded: true,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          if (!_editing && !_busy) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: _sheetOutlineStyle(),
              onPressed: () {
                final gridId = _toIntId(f.gridId);
                if (gridId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('격자 정보가 없습니다')),
                  );
                  return;
                }
                Navigator.pop(context, MapFocusTarget(gridId: gridId));
              },
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('피드백 위치로 이동'),
            ),
          ],
          const SizedBox(height: 12),
          if (_busy)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_editing)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: _sheetOutlineStyle(),
                    onPressed: () {
                      setState(() {
                        _editing = false;
                        _comment.text = f.comment ?? '';
                        _feeling = _safetyFeelings.contains(f.safetyFeeling)
                            ? f.safetyFeeling!
                            : _safetyFeelings[1];
                        _localImagePath = null;
                        _clearImage = false;
                        _currentImgUrl = f.imgUrl;
                        final names = f.tags.map((e) => e.trim()).toSet();
                        _selectedTagIds
                          ..clear()
                          ..addAll(
                            _allTags
                                .where((t) => names.contains(t.name))
                                .map((t) => t.id),
                          );
                      });
                    },
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: _sheetFilledStyle(),
                    onPressed: _save,
                    child: const Text('저장'),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: _sheetOutlineStyle(),
                    onPressed: () => setState(() => _editing = true),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('수정'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: _sheetFilledStyle(background: MapUiColors.report),
                    onPressed: _delete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('삭제'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ImageEditBlock extends StatelessWidget {
  const _ImageEditBlock({
    required this.remoteUrl,
    required this.localPath,
    required this.onPick,
    required this.onClear,
  });

  final String? remoteUrl;
  final String? localPath;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasLocal = localPath != null;
    final hasRemote = resolveMediaUrl(remoteUrl) != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasLocal)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(localPath!),
              height: 160,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          )
        else if (hasRemote)
          MediaCoverImage(url: remoteUrl, expanded: false),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: _sheetOutlineStyle(),
                onPressed: onPick,
                icon: const Icon(Icons.photo_outlined, size: 18),
                label: Text(hasLocal || hasRemote ? '사진 변경' : '사진 추가'),
              ),
            ),
            if (hasLocal || hasRemote) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.close, color: _kMuted),
                tooltip: '사진 제거',
              ),
            ],
          ],
        ),
      ],
    );
  }
}
