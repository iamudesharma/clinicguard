import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../services/platform_stt.dart';
import '../state/auth_state.dart';
import '../state/call_state.dart';
import '../theme/app_theme.dart';
import '../widgets/animated_transcript_bubble.dart';
import '../widgets/aurora_background.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_button.dart';
import '../widgets/gradient_text.dart';
import '../widgets/status_pill.dart';
import '../widgets/summary_card.dart';
import '../widgets/voice_dock.dart';
import '../widgets/voice_orb.dart';
import '../widgets/voice_wave_visualizer.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ConversationViewMode _viewMode = ConversationViewMode.voiceFocus;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CallState>();
    final auth = context.watch<AuthState>();

    final idleHome = state.phase == CallPhase.idle && state.summary == null;

    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: idleHome
              ? _buildIdle(context, auth)
              : _buildActive(context, state, auth),
        ),
      ),
    );
  }

  Widget _buildIdle(BuildContext context, AuthState auth) {
    return Column(
      children: [
        _TopBar(auth: auth),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VoiceOrb(
                    mode: OrbMode.idle,
                    size: 250,
                    onTap: () => _showPatientPicker(context),
                  ),
                  const SizedBox(height: 24),
                  const GradientText(
                    'AI Clinical Triage',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Hands-free voice triage in English & हिन्दी\nInstant symptom assessment & booking',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.inkMuted, height: 1.4, fontSize: 14),
                  ),
                  const SizedBox(height: 28),
                  GlowButton(
                    label: 'Start Triage Call',
                    icon: Icons.call_rounded,
                    glow: AppColors.neonCyan,
                    onPressed: () => _showPatientPicker(context),
                  ),
                  const SizedBox(height: 16),
                  // STT settings toggle.
                  Builder(
                    builder: (context) {
                      final callState = context.watch<CallState>();
                      return _SttSettingsRow(state: callState);
                    },
                  ),
                  const SizedBox(height: 24),
                  // Quick suggestion chips
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _SuggestionPill(
                        text: 'Fever & Cough',
                        icon: Icons.thermostat_rounded,
                        onTap: () => _showPatientPicker(context),
                      ),
                      _SuggestionPill(
                        text: 'Doctor Booking',
                        icon: Icons.calendar_today_rounded,
                        onTap: () => _showPatientPicker(context),
                      ),
                      _SuggestionPill(
                        text: 'Emergency Check',
                        icon: Icons.healing_rounded,
                        onTap: () => _showPatientPicker(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActive(BuildContext context, CallState state, AuthState auth) {
    final orbMode = switch (state.phase) {
      CallPhase.connecting => OrbMode.thinking,
      CallPhase.error => OrbMode.idle,
      CallPhase.connected => orbModeFromAgentState(state.agentState),
      CallPhase.idle => OrbMode.idle,
    };

    final (statusLabel, statusColor) = switch (state.agentState) {
      'listening' => ('Listening to you…', AppColors.neonCyan),
      'thinking' => ('Analyzing symptoms…', AppColors.amberGlow),
      'speaking' => ('ClinicGuard responding…', AppColors.auroraFuchsia),
      _ => (
        switch (state.phase) {
          CallPhase.connecting => 'Connecting WebRTC…',
          CallPhase.error => state.error,
          _ => 'Triage Call Active',
        },
        AppColors.blueGrey,
      ),
    };

    return Stack(
      children: [
        Column(
          children: [
            _TopBar(
              auth: auth,
              compact: _viewMode == ConversationViewMode.chatTimeline,
              trailing: _viewMode == ConversationViewMode.chatTimeline
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceGlassStrong,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(color: AppColors.borderGlass),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VoiceWaveVisualizer(
                            width: 20,
                            height: 12,
                            barCount: 3,
                            color: statusColor,
                            level: state.micLevel,
                            active: state.agentState != 'idle',
                          ),
                          const SizedBox(width: 6),
                          Text(
                            state.agentState.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    )
                  : null,
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _viewMode == ConversationViewMode.voiceFocus
                    ? _buildVoiceFocusView(context, state, orbMode, statusLabel, statusColor)
                    : _buildChatTimelineView(context, state, orbMode, statusLabel, statusColor),
              ),
            ),
            // Bottom space for floating dock
            const SizedBox(height: 76),
          ],
        ),
        // Floating control dock anchored at bottom
        Positioned(
          left: 0,
          right: 0,
          bottom: 12,
          child: Center(
            child: state.phase != CallPhase.idle
                ? VoiceDock(
                    state: state,
                    viewMode: _viewMode,
                    onToggleViewMode: () {
                      setState(() {
                        _viewMode = _viewMode == ConversationViewMode.voiceFocus
                            ? ConversationViewMode.chatTimeline
                            : ConversationViewMode.voiceFocus;
                      });
                    },
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: GlowButton(
                      label: 'Start triage call',
                      icon: Icons.call_rounded,
                      onPressed: () => _showPatientPicker(context),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// Immersive Gemini/ChatGPT-style full-screen Voice Focus mode
  Widget _buildVoiceFocusView(
    BuildContext context,
    CallState state,
    OrbMode orbMode,
    String statusLabel,
    Color statusColor,
  ) {
    TranscriptLine? lastUserLine;
    TranscriptLine? lastAssistantLine;
    for (final line in state.transcript.reversed) {
      if (lastUserLine == null && line.role == 'user') lastUserLine = line;
      if (lastAssistantLine == null && line.role == 'assistant') {
        lastAssistantLine = line;
      }
      if (lastUserLine != null && lastAssistantLine != null) break;
    }

    return Center(
      key: const ValueKey('voiceFocus'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusPill(
              label: statusLabel,
              color: statusColor,
              subtitle: state.phase == CallPhase.connected ? 'Room: ${state.roomId}' : null,
            ),
            const SizedBox(height: 28),
            VoiceOrb(
              mode: orbMode,
              size: 240,
              level: state.micLevel,
            ),
            const SizedBox(height: 32),
            // Show both sides of the conversation — not just the last line,
            // which hid the user's words once the assistant started replying.
            if (lastUserLine != null || lastAssistantLine != null)
              Column(
                children: [
                  if (lastUserLine != null)
                    _VoiceFocusSubtitle(
                      line: lastUserLine,
                      isAgentSpeaking: false,
                    ),
                  if (lastUserLine != null && lastAssistantLine != null)
                    const SizedBox(height: 12),
                  if (lastAssistantLine != null)
                    _VoiceFocusSubtitle(
                      line: lastAssistantLine,
                      isAgentSpeaking:
                          state.agentState == 'speaking',
                    ),
                ],
              )
            else
              Text(
                'Speak clearly in English or हिन्दी\nInterrupt anytime by speaking over the AI',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.inkMuted.withValues(alpha: 0.8),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Rich Interactive Chat Timeline mode
  Widget _buildChatTimelineView(
    BuildContext context,
    CallState state,
    OrbMode orbMode,
    String statusLabel,
    Color statusColor,
  ) {
    return Column(
      key: const ValueKey('chatTimeline'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              VoiceOrb(
                mode: orbMode,
                size: 38,
                level: state.micLevel,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatusPill(
                  label: statusLabel,
                  color: statusColor,
                  subtitle: state.phase == CallPhase.connected ? 'Room: ${state.roomId}' : null,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: state.transcript.length,
            itemBuilder: (context, i) {
              final line = state.transcript[i];
              final isLast = i == state.transcript.length - 1;
              return TranscriptBubble(
                text: line.text,
                isUser: line.role == 'user',
                isSpeaking: isLast && line.role == 'assistant' && state.agentState == 'speaking',
                language: line.language,
              );
            },
          ),
        ),
        if (state.summary != null) SummaryCard(summary: state.summary!),
        _BookingCard(state: state),
      ],
    );
  }
}

class _VoiceFocusSubtitle extends StatelessWidget {
  const _VoiceFocusSubtitle({
    required this.line,
    required this.isAgentSpeaking,
  });

  final TranscriptLine line;
  final bool isAgentSpeaking;

  @override
  Widget build(BuildContext context) {
    final isUser = line.role == 'user';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlassStrong,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isUser
              ? AppColors.neonCyan.withValues(alpha: 0.35)
              : AppColors.borderGlassStrong,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 18,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isUser
                    ? Icons.account_circle_outlined
                    : Icons.health_and_safety_outlined,
                size: 14,
                color: isUser ? AppColors.neonCyan : AppColors.auroraFuchsia,
              ),
              const SizedBox(width: 6),
              Text(
                isUser ? 'You said:' : 'ClinicGuard AI:',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isUser ? AppColors.neonCyan : AppColors.inkMuted,
                ),
              ),
              if (isAgentSpeaking && !isUser) ...[
                const SizedBox(width: 8),
                const VoiceWaveVisualizer(
                  width: 24,
                  height: 10,
                  barCount: 3,
                  color: AppColors.auroraFuchsia,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            line.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              height: 1.4,
              fontWeight: FontWeight.w500,
              color: isUser && !line.isFinal
                  ? AppColors.inkMuted
                  : AppColors.ink,
              fontStyle:
                  isUser && !line.isFinal ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionPill extends StatelessWidget {
  const _SuggestionPill({
    required this.text,
    required this.icon,
    required this.onTap,
  });

  final String text;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceGlass,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: AppColors.borderGlass),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: AppColors.neonCyan),
              const SizedBox(width: 6),
              Text(
                text,
                style: const TextStyle(fontSize: 12, color: AppColors.inkMuted, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final AuthState auth;
  final bool compact;
  final Widget? trailing;

  const _TopBar({required this.auth, this.compact = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppGradients.geminiRadiant,
              boxShadow: [
                BoxShadow(
                  color: AppColors.neonCyan.withValues(alpha: 0.4),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(
              Icons.health_and_safety_rounded,
              size: 18,
              color: AppColors.onGradient,
            ),
          ),
          const SizedBox(width: 10),
          const GradientText(
            'ClinicGuard Triage',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
          ),
          const Spacer(),
          ?trailing,
          if (!auth.isGuest) ...[
            const SizedBox(width: 8),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.surfaceGlass,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.borderGlass),
              ),
              child: IconButton(
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.logout_rounded, size: 18),
                color: AppColors.inkMuted,
                tooltip: 'Sign out',
                onPressed: () async {
                  final call = context.read<CallState>();
                  if (call.phase != CallPhase.idle) await call.endCall();
                  if (!context.mounted) return;
                  final authState = context.read<AuthState>();
                  if (authState.isGuest) {
                    authState.exitGuest();
                  } else {
                    await authState.signOut();
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BookingCard extends StatefulWidget {
  final CallState state;
  const _BookingCard({required this.state});

  @override
  State<_BookingCard> createState() => _BookingCardState();
}

class _BookingCardState extends State<_BookingCard> {
  Future<List<dynamic>>? _slotsFuture;
  bool _slotsRequested = false;

  CallState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _ensureSlotsFuture();
  }

  @override
  void didUpdateWidget(covariant _BookingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureSlotsFuture();
  }

  void _ensureSlotsFuture() {
    if (_slotsRequested) return;
    if (state.phase != CallPhase.idle || state.summary == null) return;
    _slotsRequested = true;
    _slotsFuture = ApiClient().fetchSlots();
  }

  void _retry() {
    setState(() {
      _slotsFuture = ApiClient().fetchSlots();
    });
  }

  Future<void> _book(Map<String, dynamic> slot) async {
    final ok = await state.bookAppointment((slot['label'] ?? '').toString());
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not book: ${state.bookingError}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (state.phase != CallPhase.idle || state.summary == null) {
      return const SizedBox.shrink();
    }
    final booking = state.booking;
    return GlassCard(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      glow: AppColors.teal,
      glowOpacity: 0.22,
      child: booking != null ? _confirmedContent(booking) : _bookingForm(),
    );
  }

  Widget _confirmedContent(Map<String, dynamic> booking) {
    final name = (booking['name'] ?? '').toString();
    final reason = (booking['reason'] ?? '').toString();
    final subtitle = [name, reason].where((v) => v.isNotEmpty).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle, color: AppColors.success),
            const SizedBox(width: 8),
            const Text(
              'Appointment booked',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.ink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${booking['slot'] ?? ''} · ${booking['id'] ?? ''}',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: AppColors.ink,
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: AppColors.inkMuted)),
        ],
      ],
    );
  }

  Widget _bookingForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.calendar_month_rounded, color: AppColors.neonCyan),
            const SizedBox(width: 8),
            const Text(
              'Book an appointment',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.ink,
              ),
            ),
          ],
        ),
        if (state.bookingInProgress) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 4),
        ],
        const SizedBox(height: 8),
        FutureBuilder<List<dynamic>>(
          future: _slotsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (snapshot.hasError) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Could not load slots: ${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.inkMuted),
                  ),
                  TextButton(onPressed: _retry, child: const Text('Retry')),
                ],
              );
            }
            final slots = snapshot.data ?? [];
            if (slots.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No slots available.',
                  style: TextStyle(color: AppColors.inkMuted),
                ),
              );
            }
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final slot in slots)
                  ActionChip(
                    label: Text((slot['label'] ?? '').toString()),
                    onPressed: state.bookingInProgress
                        ? null
                        : () => _book(slot),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

Future<void> _showPatientPicker(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => const SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: _PatientPickerSheet(),
      ),
    ),
  );
}

class _PatientPickerSheet extends StatefulWidget {
  const _PatientPickerSheet();

  @override
  State<_PatientPickerSheet> createState() => _PatientPickerSheetState();
}

class _PatientPickerSheetState extends State<_PatientPickerSheet> {
  late Future<List<dynamic>> _patientsFuture;

  @override
  void initState() {
    super.initState();
    _patientsFuture = ApiClient().fetchPatients();
  }

  void _retry() {
    _patientsFuture = ApiClient().fetchPatients();
    setState(() {});
  }

  Future<void> _createPatient() async {
    final auth = context.read<AuthState>();
    final call = context.read<CallState>();
    final navigator = Navigator.of(context);
    final formKey = GlobalKey<FormState>();
    final nameCtrl = TextEditingController();
    final ageCtrl = TextEditingController();
    final sexCtrl = TextEditingController();
    final conditionsCtrl = TextEditingController();
    final allergiesCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New patient'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name *'),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Name is required'
                      : null,
                ),
                TextFormField(
                  controller: ageCtrl,
                  decoration: const InputDecoration(labelText: 'Age'),
                ),
                TextFormField(
                  controller: sexCtrl,
                  decoration: const InputDecoration(labelText: 'Sex'),
                ),
                TextFormField(
                  controller: conditionsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Known conditions',
                  ),
                ),
                TextFormField(
                  controller: allergiesCtrl,
                  decoration: const InputDecoration(labelText: 'Allergies'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => navigator.pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              try {
                final created = await ApiClient().createPatient(
                  name: nameCtrl.text.trim(),
                  age: ageCtrl.text.trim(),
                  sex: sexCtrl.text.trim(),
                  knownConditions: conditionsCtrl.text.trim(),
                  allergies: allergiesCtrl.text.trim(),
                  ownerId: auth.isSignedIn ? auth.user?.id ?? '' : '',
                );
                if (!dialogContext.mounted) return;
                navigator.pop(); // close dialog
                if (!mounted) return;
                navigator.pop(); // close picker sheet
                await call.startCall(patientId: created['id']?.toString());
              } catch (e) {
                if (!dialogContext.mounted) return;
                navigator.pop();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not create patient: $e')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    nameCtrl.dispose();
    ageCtrl.dispose();
    sexCtrl.dispose();
    conditionsCtrl.dispose();
    allergiesCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.person_pin_rounded, color: AppColors.neonCyan),
              const SizedBox(width: 8),
              Text(
                'Who is calling?',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<dynamic>>(
            future: _patientsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      Text(
                        'Could not load patients: ${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.inkMuted),
                      ),
                      TextButton(onPressed: _retry, child: const Text('Retry')),
                    ],
                  ),
                );
              }
              final auth = context.read<AuthState>();
              final data = snapshot.data ?? [];
              final patients = auth.isSignedIn
                  ? data.where((p) => p['owner_id'] == auth.user?.id).toList()
                  : List<dynamic>.from(data);

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      radius: 22,
                      backgroundColor: AppColors.surfaceGlassStrong,
                      child: const Icon(
                        Icons.person_add_rounded,
                        color: AppColors.neonCyan,
                      ),
                    ),
                    title: const Text('New patient', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Create a clinical profile', style: TextStyle(color: AppColors.inkMuted, fontSize: 12)),
                    onTap: _createPatient,
                  ),
                  if (patients.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'No patients yet — create one or call as guest.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.inkMuted),
                      ),
                    )
                  else
                    for (final p in patients) _PatientTile(patient: p),
                  // Signed-in users must pick (or create) a patient profile so
                  // the agent greets them by name; only guests can call without
                  // a profile.
                  if (!auth.isSignedIn) ...[
                    const Divider(color: AppColors.borderGlass),
                    ListTile(
                      leading: const CircleAvatar(
                        radius: 22,
                        backgroundColor: AppColors.surfaceGlass,
                        child: Icon(Icons.person_off_outlined, color: AppColors.inkMuted),
                      ),
                      title: const Text('Call as guest', style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: const Text('No profile required', style: TextStyle(color: AppColors.inkMuted, fontSize: 12)),
                      onTap: () {
                        final call = context.read<CallState>();
                        Navigator.pop(context);
                        unawaited(call.startCall());
                      },
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PatientTile extends StatelessWidget {
  final Map<String, dynamic> patient;
  const _PatientTile({required this.patient});

  @override
  Widget build(BuildContext context) {
    final name = patient['name']?.toString() ?? 'Patient';
    final age = patient['age']?.toString() ?? '';
    final sex = patient['sex']?.toString() ?? '';
    final conditions = patient['known_conditions']?.toString() ?? '';
    final initials = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0])
        .join()
        .toUpperCase();

    var subtitle = (age.isEmpty && sex.isEmpty) ? '' : '$age · $sex';
    if (conditions.isNotEmpty) {
      subtitle = subtitle.isEmpty ? conditions : '$subtitle · $conditions';
    }

    return ListTile(
      leading: ClipOval(
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: const BoxDecoration(gradient: AppGradients.geminiRadiant),
          child: Text(
            initials,
            style: const TextStyle(
              color: AppColors.onGradient,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ),
      ),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle, style: const TextStyle(color: AppColors.inkMuted, fontSize: 12)),
      onTap: () {
        final call = context.read<CallState>();
        Navigator.pop(context);
        unawaited(call.startCall(patientId: patient['id']?.toString()));
      },
    );
  }
}

/// Row with STT toggle and language selector.
/// Shown on the idle home screen before starting a call.
class _SttSettingsRow extends StatefulWidget {
  final CallState state;
  const _SttSettingsRow({required this.state});

  @override
  State<_SttSettingsRow> createState() => _SttSettingsRowState();
}

class _SttSettingsRowState extends State<_SttSettingsRow> {
  List<SttLocale> _locales = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLocales();
  }

  Future<void> _loadLocales() async {
    final locales = await widget.state.getSttLocales();
    if (mounted) {
      setState(() {
        _locales = locales.isNotEmpty
            ? locales
            : [
                const SttLocale(localeId: '', name: 'Auto (Device Default)'),
                const SttLocale(localeId: 'en-IN', name: 'English (India)'),
                const SttLocale(localeId: 'en-US', name: 'English (US)'),
                const SttLocale(localeId: 'hi-IN', name: 'Hindi (India)'),
              ];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final callState = widget.state;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.borderGlass),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.mic_rounded, size: 18, color: AppColors.neonCyan),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Use device speech recognition',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              Switch(
                value: callState.usePlatformStt,
                onChanged: (v) => callState.setUsePlatformStt(v),
                activeThumbColor: AppColors.neonCyan,
              ),
            ],
          ),
          if (callState.usePlatformStt) ...[
            const Divider(height: 16, color: AppColors.borderGlass),
            Row(
              children: [
                const Icon(Icons.language_rounded, size: 18, color: AppColors.inkMuted),
                const SizedBox(width: 8),
                const Text('Language:', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                Expanded(
                  child: _loading
                      ? const Text('Loading...', style: TextStyle(fontSize: 13, color: AppColors.inkMuted))
                      : DropdownButton<String>(
                          value: callState.sttLocaleId,
                          isExpanded: true,
                          underline: const SizedBox(),
                          dropdownColor: AppColors.surfaceGlassStrong,
                          style: const TextStyle(fontSize: 13, color: AppColors.onGradient),
                          items: _locales.map((l) {
                            return DropdownMenuItem(
                              value: l.localeId,
                              child: Text(l.name),
                            );
                          }).toList(),
                          onChanged: (v) {
                            if (v != null) callState.setSttLocale(v);
                          },
                         ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows a follow-up reminder banner when a pending follow-up exists.
class _FollowUpBanner extends StatefulWidget {
  const _FollowUpBanner();

  @override
  State<_FollowUpBanner> createState() => _FollowUpBannerState();
}

class _FollowUpBannerState extends State<_FollowUpBanner> {
  List<dynamic> _followUps = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFollowUps();
  }

  Future<void> _loadFollowUps() async {
    try {
      final followUps = await ApiClient().fetchFollowUps(status: 'pending');
      if (mounted) setState(() { _followUps = followUps; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _followUps.isEmpty) return const SizedBox.shrink();
    final followUp = _followUps.first;
    final reason = followUp['reason'] ?? '';
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      glow: AppColors.amberGlow,
      glowOpacity: 0.2,
      child: ListTile(
        leading: const Icon(Icons.follow_the_signs, color: AppColors.amberGlow),
        title: const Text('Follow-up check-in', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          reason.isNotEmpty ? 'Regarding: $reason' : 'How are you feeling today?',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () {
          // TODO: start follow-up call with previous context
        },
      ),
    );
  }
}
