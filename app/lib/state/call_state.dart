import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voice_forge_flutter/voice_forge_flutter.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../vad/barge_in_detector.dart';
import '../vad/mic_tap.dart';

enum CallPhase { idle, connecting, connected, error }

class TranscriptLine {
  final String role; // user | assistant
  final String text;
  final bool isFinal;
  final String language;

  const TranscriptLine({
    required this.role,
    required this.text,
    required this.isFinal,
    this.language = '',
  });
}

/// Voice call state driven by [VoiceCallController] (voice_forge transport):
/// microphone -> WebRTC -> voice_forge agent, with the `agent.events`
/// data-channel contract (user_transcript / assistant_text / agent_state /
/// summary). Barge-in is handled server-side by the agent's own VAD + onset
/// gate; on web the app additionally taps the mic PCM and sends an instant
/// `barge_in` the moment the user starts talking over the agent.
class CallState extends ChangeNotifier {
  final ApiClient _api = ApiClient();

  bool _disposed = false;

  VoiceCallController? _call;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  StreamSubscription<VoiceCallPhase>? _phaseSub;
  RealtimeChannel? _ehrChannel;
  String? _roomId;
  String? _pendingPatientId;
  Timer? _patientIdTimer;

  final MicTap _micTap = createMicTap();
  bool _bargeInArmed = false;
  late final BargeInDetector _bargeInDetector;

  /// Live mic RMS level (0..1, web only; native stays 0). Drives the voice
  /// orb's speaking animation without rebuilding the tree at audio rate.
  final ValueNotifier<double> micLevel = ValueNotifier<double>(0);

  CallState() {
    _bargeInDetector = BargeInDetector(
      rmsThreshold: AppConfig.bargeInRmsThreshold,
      onSpeechStart: _onLocalSpeechStart,
      onSpeechEnd: _onLocalSpeechEnd,
      onAudioLevel: (level) => micLevel.value = level,
    );
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  CallPhase phase = CallPhase.idle;
  String error = '';
  String agentState = 'idle'; // listening | thinking | speaking | idle
  final List<TranscriptLine> transcript = [];
  Map<String, dynamic>? _summary;

  Map<String, dynamic>? get summary => _summary;
  bool micEnabled = false;

  Map<String, dynamic>? booking;
  String bookingError = '';
  bool bookingInProgress = false;

  String get roomId => _roomId ?? '';
  bool get isConnected => phase == CallPhase.connected;

  Future<void> startCall({String? patientId}) async {
    if (_call != null) return;
    _pendingPatientId = patientId;
    phase = CallPhase.connecting;
    error = '';
    booking = null;
    bookingError = '';
    bookingInProgress = false;
    notifyListeners();

    try {
      final call = VoiceCallController(signalingUrl: AppConfig.signalingUrl);
      _call = call;

      _phaseSub = call.phase.listen((p) {
        if (_disposed) return;
        switch (p) {
          case VoiceCallPhase.connecting:
            phase = CallPhase.connecting;
          case VoiceCallPhase.connected:
            phase = CallPhase.connected;
          case VoiceCallPhase.error:
            phase = CallPhase.error;
            error = 'Call failed';
          case VoiceCallPhase.idle:
            phase = CallPhase.idle;
        }
        notifyListeners();
      });

      _eventsSub = call.events.listen(_onEvent);

      await call.start();
      // Tap the mic PCM on web for instant barge-in; no-op elsewhere.
      final local = call.localStream;
      if (local != null) _micTap.start(local, _bargeInDetector);
      // The data channel opens asynchronously after WebRTC negotiation;
      // keep retrying until the patient id is actually delivered.
      _patientIdTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
        if (_pendingPatientId == null) {
          _patientIdTimer?.cancel();
          _patientIdTimer = null;
        } else {
          unawaited(_sendPatientId());
        }
      });
      micEnabled = true;
      _subscribeEhrRealtime();
      phase = CallPhase.connected;
      notifyListeners();
    } catch (e) {
      error = 'Could not start the call: $e';
      phase = CallPhase.error;
      notifyListeners();
    }
  }

  Future<void> endCall() async {
    final call = _call;
    _call = null;
    _micTap.stop();
    _bargeInArmed = false;
    _bargeInDetector.reset();
    _pendingPatientId = null;
    _patientIdTimer?.cancel();
    _patientIdTimer = null;
    phase = CallPhase.idle;
    _summary = null;
    micLevel.value = 0;
    booking = null;
    bookingError = '';
    bookingInProgress = false;
    notifyListeners();
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _phaseSub?.cancel();
    _phaseSub = null;
    await _ehrChannel?.unsubscribe();
    _ehrChannel = null;
    await call?.end();
  }

  Future<void> toggleMic() async {
    final call = _call;
    if (call == null) return;
    micEnabled = !micEnabled;
    await call.setMicEnabled(micEnabled);
    notifyListeners();
  }

  Future<void> refreshSummary() async {
    final room = _roomId;
    if (room == null || room.isEmpty) return;
    try {
      _summary = await _api.fetchSummary(room);
      notifyListeners();
    } catch (e) {
      error = 'Summary unavailable: $e';
      notifyListeners();
    }
  }

  /// When Supabase is configured, EHR summaries inserted by the backend arrive
  /// via realtime and update the summary card without a data-channel round trip.
  void _subscribeEhrRealtime() {
    if (AppConfig.supabaseUrl.isEmpty) return;
    final client = Supabase.instance.client;
    final channel = client
        .channel('ehr-live')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'ehr_summaries',
          callback: (payload) {
            final row = payload.newRecord;
            final summary = row['summary'];
            if (summary is Map<String, dynamic>) {
              _summary = summary;
              notifyListeners();
            }
          },
        );
    _ehrChannel = channel;
    channel.subscribe();
  }

  /// Books the given slot (label from GET /slots) for this session.
  Future<bool> bookAppointment(String slotLabel) async {
    final room = _roomId;
    if (room == null || room.isEmpty) return false;
    bookingInProgress = true;
    bookingError = '';
    notifyListeners();
    try {
      booking = await _api.createBooking(
        slot: slotLabel,
        roomId: room,
        patientId: '',
        name: (_summary?['patient_name'] ?? '').toString(),
        reason: (_summary?['chief_complaint'] ?? '').toString(),
      );
      notifyListeners();
      return true;
    } catch (e) {
      bookingError = '$e';
      notifyListeners();
      return false;
    } finally {
      bookingInProgress = false;
      notifyListeners();
    }
  }

  Future<void> _sendPatientId() async {
    final id = _pendingPatientId;
    if (id == null) return;
    if (_call?.dataChannelOpen != true) return; // channel not up yet — retried
    _pendingPatientId = null;
    await _call?.send({'event': 'patient_id', 'patient_id': id});
  }

  /// The user started talking while the agent was speaking: tell the agent
  /// to stop right now (the interrupted utterance is picked up by its VAD
  /// and still answered).
  void _onLocalSpeechStart() {
    if (!_bargeInArmed) return;
    final call = _call;
    if (call == null || !call.dataChannelOpen) return;
    _bargeInArmed = false; // one shot until the next speaking turn
    call.sendBargeIn();
  }

  void _onLocalSpeechEnd() {}

  void _onEvent(Map<String, dynamic> payload) {
    switch (payload['type']) {
      case 'connected':
        _roomId = payload['room'] as String?;
        if (_pendingPatientId != null) unawaited(_sendPatientId());
        break;
      case 'user_transcript':
        transcript.add(TranscriptLine(
          role: 'user',
          text: payload['text'] as String? ?? '',
          isFinal: payload['is_final'] == true,
          language: payload['language'] as String? ?? '',
        ));
        break;
      case 'assistant_text':
        transcript.add(TranscriptLine(
          role: 'assistant',
          text: payload['text'] as String? ?? '',
          isFinal: true,
        ));
        break;
      case 'agent_state':
        agentState = payload['state'] as String? ?? 'idle';
        // Arm the instant barge-in detector only while the agent speaks;
        // its mic audio is our own TTS echo, so unarmed it would be noise.
        _bargeInArmed = agentState == 'speaking';
        _bargeInDetector.reset();
        break;
      case 'summary':
        _summary = payload['summary'] as Map<String, dynamic>?;
        break;
      case 'booking_confirmed':
        booking = payload['booking'] as Map<String, dynamic>?;
        bookingError = '';
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _patientIdTimer?.cancel();
    _eventsSub?.cancel();
    _phaseSub?.cancel();
    _call?.dispose();
    micLevel.dispose();
    super.dispose();
  }
}
