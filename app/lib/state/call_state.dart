import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voice_forge_flutter/voice_forge_flutter.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../services/platform_stt.dart';
import '../vad/barge_in_detector.dart';
import '../vad/mic_tap.dart';

/// Injectable for tests — avoids real WebRTC/WebSocket in unit tests.
typedef VoiceCallControllerFactory = VoiceCallController Function(
  String signalingUrl,
);

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
  final VoiceCallControllerFactory _voiceCallFactory;

  bool _disposed = false;

  VoiceCallController? _call;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  StreamSubscription<VoiceCallPhase>? _phaseSub;
  RealtimeChannel? _ehrChannel;
  String? _roomId;
  String? _pendingPatientId;
  String? _activePatientId;
  Timer? _patientIdTimer;

  final MicTap _micTap = createMicTap();
  bool _bargeInArmed = false;
  DateTime? _speakingSince;
  late final BargeInDetector _bargeInDetector;

  // Platform STT (Apple SFSpeechRecognizer / Web Speech API).
  final PlatformSttService _platformStt = PlatformSttService();
  StreamSubscription<SttResult>? _platformSttSub;
  bool _usePlatformStt = false; // toggled by user in settings
  String _sttLocaleId = ''; // e.g. 'en-IN', 'hi-IN'

  /// Live mic RMS level (0..1, web only; native stays 0). Drives the voice
  /// orb's speaking animation without rebuilding the tree at audio rate.
  final ValueNotifier<double> micLevel = ValueNotifier<double>(0);

  CallState({VoiceCallControllerFactory? voiceCallFactory})
      : _voiceCallFactory = voiceCallFactory ??
            ((url) => VoiceCallController(signalingUrl: url)) {
    _bargeInDetector = BargeInDetector(
      rmsThreshold: AppConfig.bargeInRmsThreshold,
      voicedFramesToStart: 4, // ~80ms — reduces false triggers from noise
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

  // Platform STT settings.
  bool get usePlatformStt => _usePlatformStt;
  String get sttLocaleId => _sttLocaleId;
  bool get platformSttAvailable => _platformStt.isAvailable;

  /// Toggle platform STT on/off. Call before starting a call.
  void setUsePlatformStt(bool value) {
    _usePlatformStt = value;
    notifyListeners();
  }

  /// Set the STT locale (e.g. 'en-IN', 'hi-IN').
  void setSttLocale(String localeId) {
    _sttLocaleId = localeId;
    notifyListeners();
  }

  /// Get available STT locales from the platform.
  Future<List<SttLocale>> getSttLocales() async {
    await _platformStt.initialize();
    return _platformStt.getLocales();
  }

  String get roomId => _roomId ?? '';
  bool get isConnected => phase == CallPhase.connected;

  Future<void> startCall({String? patientId}) async {
    if (_call != null) return;
    _resetSessionState();
    _activePatientId = patientId;
    _pendingPatientId = patientId;
    phase = CallPhase.connecting;
    notifyListeners();

    try {
      final call = _voiceCallFactory(AppConfig.signalingUrl);
      _call = call;

      _phaseSub = call.phase.listen((p) {
        if (_disposed) return;
        switch (p) {
          case VoiceCallPhase.connecting:
            phase = CallPhase.connecting;
          case VoiceCallPhase.connected:
            phase = CallPhase.connected;
            if (_pendingPatientId != null) unawaited(_sendPatientId());
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

      // Start platform STT if enabled (Apple/Web speech recognition).
      if (_usePlatformStt) {
        // Don't mute mic — barge-in detector needs it for speech onset.
        // Platform STT and agent STT will both process the same audio;
        // the agent's _processing flag prevents duplicate LLM calls.
        unawaited(_startPlatformStt());
      }
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
    _resetSessionState();
    // _stopPlatformStt() needs the (now local) controller to tell the agent
    // to re-enable its own STT — it must run before _call is dropped.
    _stopPlatformStt(call);
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _phaseSub?.cancel();
    _phaseSub = null;
    await _ehrChannel?.unsubscribe();
    _ehrChannel = null;
    await call?.setMicEnabled(false);
    await call?.end();
  }

  /// Clears everything that must not survive into the next call. CallState is
  /// an app-lifetime singleton; without this a new patient's call starts with
  /// the previous patient's transcript, room id and speaking/thinking state.
  void _resetSessionState() {
    transcript.clear();
    _roomId = null;
    agentState = 'idle';
    _summary = null;
    error = '';
    booking = null;
    bookingError = '';
    bookingInProgress = false;
    micEnabled = false;
    _bargeInArmed = false;
    _activePatientId = null;
    micLevel.value = 0;
    notifyListeners();
  }

  Future<void> toggleMic() async {
    final call = _call;
    if (call == null) return;
    if (_usePlatformStt) {
      // Toggle platform STT instead of WebRTC mic.
      if (_platformStt.isListening) {
        _stopPlatformStt();
        micEnabled = false;
      } else {
        unawaited(_startPlatformStt());
        micEnabled = true;
      }
    } else {
      micEnabled = !micEnabled;
      await call.setMicEnabled(micEnabled);
    }
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
  /// Filtered to the active patient: without a filter, ANY patient's
  /// ehr_summaries insert (another session, another user) would overwrite this
  /// call's summary — and leak into the booking form.
  void _subscribeEhrRealtime() {
    if (AppConfig.supabaseUrl.isEmpty) return;
    try {
      final activePatientId = _activePatientId;
      final client = Supabase.instance.client;
      final channel = client
          .channel('ehr-live')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'ehr_summaries',
            callback: (payload) {
              final row = payload.newRecord;
              if (activePatientId != null &&
                  row['patient_id']?.toString() != activePatientId) {
                return; // another patient's summary: ignore
              }
              final summary = row['summary'];
              if (summary is Map<String, dynamic>) {
                _summary = summary;
                notifyListeners();
              }
            },
          );
      _ehrChannel = channel;
      channel.subscribe();
    } catch (e) {
      debugPrint('[CallState] EHR realtime skipped: $e');
    }
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
        patientId: _activePatientId ?? '',
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
    // Grace period: don't barge-in in the first 600ms of agent speech.
    // Residual echo / room noise often trips the detector right as TTS starts.
    final since = _speakingSince;
    if (since != null &&
        DateTime.now().difference(since) < const Duration(milliseconds: 600)) {
      return;
    }
    final call = _call;
    if (call == null || !call.dataChannelOpen) return;
    _bargeInArmed = false; // one shot until the next speaking turn
    call.sendBargeIn();
  }

  void _onLocalSpeechEnd() {}

  // ---- Platform STT (Apple/Web) ----

  Future<void> _startPlatformStt() async {
    final available = await _platformStt.initialize();
    if (!available) {
      debugPrint('[CallState] platform STT not available, using agent STT');
      return;
    }
    _platformSttSub = _platformStt.results.listen(_onPlatformSttResult);
    await _platformStt.startListening(
      localeId: _sttLocaleId,
    );
    debugPrint('[CallState] platform STT started (locale: $_sttLocaleId)');
    // Tell agent to disable its own VAD/STT (avoid duplicate processing).
    // Guard: data channel may not be open yet if platform STT starts early.
    final call = _call;
    if (call != null && call.dataChannelOpen) {
      call.send({
        'event': 'platform_stt_enabled',
        'locale': _sttLocaleId,
      });
    }
  }

  void _stopPlatformStt([VoiceCallController? call]) {
    _platformSttSub?.cancel();
    _platformSttSub = null;
    _platformStt.stopListening();
    // Tell agent to re-enable its own VAD/STT.
    call ??= _call;
    if (call != null && call.dataChannelOpen) {
      call.send({'event': 'platform_stt_disabled'});
    }
  }

  void _onPlatformSttResult(SttResult result) {
    if (result.text.isEmpty) return;
    final call = _call;
    if (call == null || !call.dataChannelOpen) return;

    // Send recognized text to agent via data channel.
    call.send({
      'event': 'stt_text',
      'text': result.text,
      'is_final': result.isFinal,
    });

    // Update local transcript display.
    if (result.isFinal) {
      // Final: replace trailing partial or add new line.
      if (transcript.isNotEmpty &&
          transcript.last.role == 'user' &&
          !transcript.last.isFinal) {
        transcript.last = TranscriptLine(
          role: 'user',
          text: result.text,
          isFinal: true,
          language: _sttLocaleId,
        );
      } else {
        transcript.add(TranscriptLine(
          role: 'user',
          text: result.text,
          isFinal: true,
          language: _sttLocaleId,
        ));
      }
    } else {
      // Partial: replace trailing partial or add new line.
      if (transcript.isNotEmpty &&
          transcript.last.role == 'user' &&
          !transcript.last.isFinal) {
        transcript.last = TranscriptLine(
          role: 'user',
          text: result.text,
          isFinal: false,
          language: _sttLocaleId,
        );
      } else {
        transcript.add(TranscriptLine(
          role: 'user',
          text: result.text,
          isFinal: false,
          language: _sttLocaleId,
        ));
      }
    }
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> payload) {
    switch (payload['type']) {
      case 'connected':
        _roomId = payload['room'] as String?;
        if (_pendingPatientId != null) unawaited(_sendPatientId());
        // If platform STT was started before data channel opened, send the enable signal now.
        if (_usePlatformStt && _platformStt.isListening) {
          _call?.send({
            'event': 'platform_stt_enabled',
            'locale': _sttLocaleId,
          });
        }
        break;
      case 'user_transcript':
        final isFinal = payload['is_final'] == true;
        final text = payload['text'] as String? ?? '';
        if (isFinal) {
          // Final transcript: replace any trailing partial, then mark as final.
          if (transcript.isNotEmpty &&
              transcript.last.role == 'user' &&
              !transcript.last.isFinal) {
            transcript.last = TranscriptLine(
              role: 'user',
              text: text,
              isFinal: true,
              language: payload['language'] as String? ?? '',
            );
          } else {
            transcript.add(TranscriptLine(
              role: 'user',
              text: text,
              isFinal: true,
              language: payload['language'] as String? ?? '',
            ));
          }
        } else {
          // Partial transcript: replace the trailing partial if there is one,
          // otherwise add a new line. This prevents duplicate partials from
          // stacking up in the UI.
          if (transcript.isNotEmpty &&
              transcript.last.role == 'user' &&
              !transcript.last.isFinal) {
            transcript.last = TranscriptLine(
              role: 'user',
              text: text,
              isFinal: false,
              language: payload['language'] as String? ?? '',
            );
          } else {
            transcript.add(TranscriptLine(
              role: 'user',
              text: text,
              isFinal: false,
              language: payload['language'] as String? ?? '',
            ));
          }
        }
        notifyListeners();
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
        if (agentState == 'speaking') {
          _speakingSince = DateTime.now();
          _bargeInArmed = true;
        } else {
          _speakingSince = null;
          _bargeInArmed = false;
        }
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
    _ehrChannel?.unsubscribe();
    _ehrChannel = null;
    _call?.dispose();
    _platformSttSub?.cancel();
    _platformStt.dispose();
    micLevel.dispose();
    super.dispose();
  }
}
