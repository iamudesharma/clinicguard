import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/auth_state.dart';
import '../theme/app_theme.dart';
import '../widgets/animated_transcript_bubble.dart';
import '../widgets/aurora_background.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_text.dart';
import '../widgets/summary_card.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const _avatarGradients = [
  AppGradients.aurora,
  AppGradients.auroraHot,
  LinearGradient(colors: [AppColors.teal, AppColors.success]),
  LinearGradient(colors: [AppColors.violet, AppColors.fuchsia]),
  LinearGradient(colors: [AppColors.cyan, AppColors.violet]),
];

String _formatTimestamp(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return iso;
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '${_months[dt.month - 1]} ${dt.day} · $hh:$mm';
}

/// Past triage call sessions, fetched from the backend control plane.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final ApiClient _api = ApiClient();
  late Future<List<dynamic>> _sessionsFuture;
  String _ownerId = '';

  @override
  void initState() {
    super.initState();
    // Eagerly assign so the late field is always initialized before build()
    // (guest mode leaves _ownerId == '' and would skip didChangeDependencies).
    _sessionsFuture = _api.fetchSessions(ownerId: '');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthState>();
    final ownerId = auth.isSignedIn ? auth.user?.id ?? '' : '';
    if (ownerId != _ownerId) {
      _ownerId = ownerId;
      _sessionsFuture = _api.fetchSessions(ownerId: ownerId);
    }
  }

  void _retry() {
    setState(() {
      _sessionsFuture = _api.fetchSessions(ownerId: _ownerId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppGradients.aurora,
                      ),
                      child: const Icon(
                        Icons.history,
                        color: AppColors.onGradient,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const GradientText(
                      'Call History',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<dynamic>>(
                  future: _sessionsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                              ),
                              child: Text(
                                'Could not load call history: ${snapshot.error}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AppColors.inkMuted,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _retry,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }
                    final sessions = snapshot.data ?? [];
                    if (sessions.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            'No calls yet — start a triage call and it will show up here.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.inkMuted),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: sessions.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final room = sessions[i] as Map<String, dynamic>;
                        final delay = math.min(i * 0.06, 1.0);
                        return TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: 1),
                          duration: const Duration(milliseconds: 450),
                          curve: Interval(
                            delay,
                            1.0,
                            curve: Curves.easeOutCubic,
                          ),
                          builder: (context, v, child) => Opacity(
                            opacity: v,
                            child: Transform.translate(
                              offset: Offset(0, 12 * (1 - v)),
                              child: child,
                            ),
                          ),
                          child: _SessionTile(
                            room: room,
                            onTap: () => _openSession(context, room),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSession(BuildContext context, Map<String, dynamic> room) {
    final name = (room['patient_name'] ?? '').toString();
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailScreen(
          roomId: (room['room_id'] ?? '').toString(),
          patientName: name,
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final Map<String, dynamic> room;
  final VoidCallback onTap;

  const _SessionTile({required this.room, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final patientName = (room['patient_name'] ?? '').toString();
    final count = (room['transcript_count'] ?? 0).toString();
    final bookingCount = room['booking_count'] as int? ?? 0;

    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.all(14),
        radius: 20,
        glow: AppColors.cyan,
        glowOpacity: 0.12,
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient:
                    _avatarGradients[patientName.hashCode.abs() %
                        _avatarGradients.length],
              ),
              child: Center(
                child: Text(
                  patientName.isNotEmpty ? patientName[0].toUpperCase() : 'G',
                  style: const TextStyle(
                    color: AppColors.onGradient,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    patientName.isNotEmpty ? patientName : 'Guest',
                    style: const TextStyle(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_formatTimestamp((room['created_at'] ?? '').toString())} · $count msgs',
                    style: const TextStyle(
                      color: AppColors.inkFaint,
                      fontSize: 12,
                    ),
                  ),
                  if (bookingCount > 0) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceGlass,
                        border: Border.all(color: AppColors.borderGlass),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.event_available,
                            size: 14,
                            color: AppColors.success,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Appointment booked${bookingCount > 1 ? ' ($bookingCount)' : ''}',
                            style: const TextStyle(
                              color: AppColors.success,
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: AppColors.inkFaint),
          ],
        ),
      ),
    );
  }
}

class _SessionData {
  final List<dynamic> transcripts;
  final Map<String, dynamic>? summary;
  final List<dynamic> bookings;

  const _SessionData({
    required this.transcripts,
    required this.summary,
    required this.bookings,
  });
}

/// Detail view for one past session: summary, appointment and transcript.
class SessionDetailScreen extends StatefulWidget {
  final String roomId;
  final String patientName;

  const SessionDetailScreen({
    super.key,
    required this.roomId,
    required this.patientName,
  });

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  final ApiClient _api = ApiClient();
  late Future<_SessionData> _future;
  Map<String, dynamic>? _summary;
  bool _summaryLoading = true;

  @override
  void initState() {
    super.initState();
    _future = _load();
    unawaited(_loadSummary());
  }

  /// Transcripts + bookings load immediately; the summary is generated
  /// on-demand by the backend (slow free-tier LLM) and fills in when ready.
  Future<_SessionData> _load() async {
    final results = await Future.wait([
      _api.fetchTranscripts(widget.roomId).catchError((_) => <dynamic>[]),
      _api.fetchBookings(widget.roomId).catchError((_) => <dynamic>[]),
    ]);
    return _SessionData(
      transcripts: results[0],
      summary: null,
      bookings: results[1],
    );
  }

  Future<void> _loadSummary() async {
    setState(() => _summaryLoading = true);
    try {
      final summary = await _api.fetchSummary(widget.roomId);
      if (!mounted) return;
      setState(() => _summary = summary);
    } catch (_) {
      // no transcript / generation failed → show the session without a summary
    } finally {
      if (mounted) setState(() => _summaryLoading = false);
    }
  }

  void _retry() {
    setState(() {
      _future = _load();
    });
    unawaited(_loadSummary());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 20, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.surfaceGlass,
                        foregroundColor: AppColors.ink,
                        side: const BorderSide(color: AppColors.borderGlass),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.patientName.isNotEmpty
                                ? widget.patientName
                                : 'Session',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.ink,
                              fontWeight: FontWeight.w700,
                              fontSize: 18,
                            ),
                          ),
                          Text(
                            widget.roomId,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.inkFaint,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<_SessionData>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                              ),
                              child: Text(
                                'Could not load session: ${snapshot.error}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AppColors.inkMuted,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _retry,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }
                    final data = snapshot.data!;
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        if (_summary != null) SummaryCard(summary: _summary!),
                        if (_summaryLoading)
                          GlassCard(
                            padding: const EdgeInsets.all(16),
                            radius: 16,
                            child: const Row(
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Text(
                                  'Generating EHR summary…',
                                  style: TextStyle(color: AppColors.inkMuted),
                                ),
                              ],
                            ),
                          ),
                        if (data.bookings.isNotEmpty)
                          _AppointmentCard(bookings: data.bookings),
                        if (data.transcripts.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(
                              child: Text(
                                'No transcript available for this session.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppColors.inkMuted),
                              ),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Column(
                              children: [
                                for (final line in data.transcripts)
                                  TranscriptBubble(
                                    text: (line['text'] ?? '').toString(),
                                    isUser: line['role'] == 'user',
                                  ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppointmentCard extends StatelessWidget {
  final List<dynamic> bookings;

  const _AppointmentCard({required this.bookings});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      glow: AppColors.teal,
      glowOpacity: 0.2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.event_available, color: AppColors.teal, size: 20),
              SizedBox(width: 8),
              Text(
                'Appointment',
                style: TextStyle(
                  color: AppColors.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final booking in bookings)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${booking['slot'] ?? ''} · ${booking['id'] ?? ''}',
                style: const TextStyle(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
