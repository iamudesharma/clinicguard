import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../vad/barge_in_controller.dart';

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

class CallState extends ChangeNotifier {
  final ApiClient _api = ApiClient();

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  BargeInController? _bargeIn;
  RealtimeChannel? _ehrChannel;
  String? _roomId;

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
    if (_room != null) return;
    phase = CallPhase.connecting;
    error = '';
    notifyListeners();

    try {
      final token = await _api.fetchToken(userId: AppConfig.defaultUserId);
      _roomId = token.room;

      final room = Room(
        roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
      );
      await room.connect(token.url, token.token);
      await room.localParticipant?.setMicrophoneEnabled(true);

      _room = room;
      final bargeIn = BargeInController(room: room);
      _bargeIn = bargeIn;
      _listener = room.createListener()
        ..on<DataReceivedEvent>(_onDataReceived)
        ..on<ParticipantConnectedEvent>((e) {
          if (e.participant.kind == ParticipantKind.AGENT) {
            agentState = 'connected';
            notifyListeners();
          }
        })
        ..on<TrackSubscribedEvent>((e) {
          if (e.participant.kind == ParticipantKind.AGENT &&
              e.track is RemoteAudioTrack) {
            bargeIn.setAgentTrack(e.track as RemoteAudioTrack);
          }
        });

      _armBargeIn(bargeIn);
      _subscribeEhrRealtime();
      micEnabled = true;
      phase = CallPhase.connected;
      notifyListeners();
    } catch (e) {
      error = 'Could not start the call: $e';
      phase = CallPhase.error;
      notifyListeners();
    }
  }

  /// Grabs the published mic track (may arrive a tick after unmute) and arms
  /// the local barge-in detector on its raw PCM stream.
  Future<void> _armBargeIn(BargeInController controller) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final pub = _room?.localParticipant?.audioTrackPublications
          .where((p) => p.kind == TrackType.AUDIO)
          .firstOrNull;
      final micTrack = pub?.track;
      if (micTrack is LocalAudioTrack) {
        await controller.start(micTrack);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    debugPrint('[barge-in] mic track not found, detector not armed');
  }

  Future<void> endCall() async {
    final room = _room;
    _room = null;
    _roomId = null;
    phase = CallPhase.idle;
    _summary = null;
    notifyListeners();
    await _listener?.dispose();
    _listener = null;
    await _ehrChannel?.unsubscribe();
    _ehrChannel = null;
    await _bargeIn?.stop();
    _bargeIn = null;
    await room?.disconnect();
  }

  Future<void> toggleMic() async {
    final room = _room;
    if (room == null) return;
    micEnabled = !micEnabled;
    await room.localParticipant?.setMicrophoneEnabled(micEnabled);
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

  void _onDataReceived(DataReceivedEvent e) {
    if (e.topic != 'agent.events') return;
    final payload = _decodePayload(e.data);
    if (payload == null) return;

    switch (payload['type']) {
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

  Map<String, dynamic>? _decodePayload(List<int> data) {
    try {
      return jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _listener?.dispose();
    _room?.disconnect();
    super.dispose();
  }
}
