import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:clinic_guard/state/call_state.dart';

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
    final state = CallState();

    // Stale state from a previous call (startCall with _call == null should
    // wipe it before entering connecting).
    state.transcript.add(const TranscriptLine(
      role: 'assistant',
      text: 'old reply',
      isFinal: true,
    ));
    state.agentState = 'speaking';

    // In a unit test the WebRTC controller cannot start; startCall reports
    // phase=error asynchronously (the transport failure). The reset must have
    // happened before that.
    // Swallow the async transport error so it can't fail the test zone.
    unawaited(state.startCall(patientId: 'PAT-ABC123').catchError((_) {}));
    for (var i = 0; i < 50 && state.phase != CallPhase.error; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(state.phase, CallPhase.error);

    expect(state.transcript, isEmpty);
    expect(state.agentState, 'idle');
    expect(state.summary, isNull);
    expect(state.roomId, isEmpty);
  });
}
