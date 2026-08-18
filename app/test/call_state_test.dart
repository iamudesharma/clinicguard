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

    // _resetSessionState() runs synchronously at the top of startCall, before
    // any WebRTC/signaling await. Don't gate this on transport failure — CI
    // runners may keep the call in connecting for seconds.
    final callFuture = state.startCall(patientId: 'PAT-ABC123');

    expect(state.transcript, isEmpty);
    expect(state.agentState, 'idle');
    expect(state.summary, isNull);
    expect(state.roomId, isEmpty);
    expect(state.phase, CallPhase.connecting);

    // Tear down the in-flight call so timers/subscriptions don't leak.
    unawaited(callFuture.catchError((_) {}));
    await state.endCall();
  });
}
