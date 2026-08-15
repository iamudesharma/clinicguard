import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voicepipe_flutter/voicepipe_flutter.dart';

import '../config.dart';
import '../services/api_client.dart';

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

/// Voice call state driven by [VoiceCallController] (voicepipe transport):
/// microphone -> WebRTC -> voicepipe agent, with the `agent.events`
/// data-channel contract (user_transcript / assistant_text / agent_state /
/// summary). Barge-in is handled server-side by the agent's own VAD.
class CallState extends ChangeNotifier {
  final ApiClient _api = ApiClient();

  bool _disposed = false;

  VoiceCallController? _call;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  StreamSubscription<VoiceCallPhase>? _phaseSub;
  RealtimeChannel? _ehrChannel;
  String? _roomId;

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

  String get roomId => _roomId ?? '';
  bool get isConnected => phase == CallPhase.connected;

  Future<void> startCall() async {
    if (_call != null) return;
    phase = CallPhase.connecting;
    error = '';
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
    _roomId = null;
    phase = CallPhase.idle;
    _summary = null;
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

  void _onEvent(Map<String, dynamic> payload) {
    switch (payload['type']) {
      case 'connected':
        _roomId = payload['room'] as String?;
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
        break;
      case 'summary':
        _summary = payload['summary'] as Map<String, dynamic>?;
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _eventsSub?.cancel();
    _phaseSub?.cancel();
    _call?.dispose();
    super.dispose();
  }
}
