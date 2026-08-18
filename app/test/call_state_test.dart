import 'package:flutter_test/flutter_test.dart';
import 'package:voice_forge_flutter/voice_forge_flutter.dart';

import 'package:clinic_guard/state/call_state.dart';

/// No WebRTC/WebSocket — unit tests must not touch the network (CI has no agent).
class _FakeVoiceCallController extends VoiceCallController {
  _FakeVoiceCallController() : super(signalingUrl: 'ws://test-fake');

  @override
  Future<void> start() async {}

  @override
  Future<void> end() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('endCall clears all per-call state (no cross-patient leak)', () async {
    final state = CallState();

    // Simulate an active call with transcript, status, summary and booking.
    state.phase = CallPhase.connected;
    state.agentState = 'speaking';
    state.transcript.add(const TranscriptLine(
      role: 'user',
      text: 'I have a fever',
      isFinal: true,
    ));
    state.transcript.add(const TranscriptLine(
      role: 'assistant',
      text: 'How long have you had it?',
      isFinal: true,
    ));

    await state.endCall();

    expect(state.transcript, isEmpty,
        reason: 'previous patient transcript must not leak into the next call');
    expect(state.agentState, 'idle');
    expect(state.phase, CallPhase.idle);
    expect(state.roomId, isEmpty);
    expect(state.summary, isNull);
    expect(state.micEnabled, isFalse);
    expect(state.booking, isNull);
    expect(state.bookingError, isEmpty);
    expect(state.bookingInProgress, isFalse);
  });

  test('startCall resets stale state before connecting', () async {
    final state = CallState(
      voiceCallFactory: (_) => _FakeVoiceCallController(),
    );

    // Stale state from a previous call.
    state.transcript.add(const TranscriptLine(
      role: 'assistant',
      text: 'old reply',
      isFinal: true,
    ));
    state.agentState = 'speaking';

    await state.startCall(patientId: 'PAT-ABC123');

    expect(state.transcript, isEmpty);
    expect(state.agentState, 'idle');
    expect(state.summary, isNull);
    expect(state.roomId, isEmpty);
    expect(state.phase, CallPhase.connected);

    await state.endCall();
    expect(state.phase, CallPhase.idle);
  });
}
