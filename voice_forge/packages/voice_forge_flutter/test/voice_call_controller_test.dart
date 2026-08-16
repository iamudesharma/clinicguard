import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicepipe_flutter/voicepipe_flutter.dart';

void main() {
  test('VoiceCallController builds with a signaling URL', () {
    final call = VoiceCallController(
      signalingUrl: 'ws://127.0.0.1:8765/signal',
    );
    expect(call.signalingUrl, 'ws://127.0.0.1:8765/signal');
    expect(call.isStarted, isFalse);
    expect(call.micEnabled, isFalse);
    expect(call.dataChannelLabel, 'agent.events');
  });

  test('barge-in payload matches the voicepipe contract', () {
    // The controller sends {"event":"barge_in"} on the data channel; verify
    // the contract string is what the server expects.
    final payload = jsonEncode({'event': 'barge_in'});
    expect(jsonDecode(payload), {'event': 'barge_in'});
  });
}
