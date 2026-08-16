# voice_forge_flutter

Flutter client for [voice_forge](https://github.com/example/voice_forge) voice
agents: mic → WebRTC → agent, with the `agent.events` data-channel contract,
automatic playback of agent audio, and instant barge-in.

Pure Dart on top of `flutter_webrtc` + `web_socket_channel` — works on web,
iOS, Android, and desktop. No LiveKit, no tokens.

## Features

- One-tap voice calls: `VoiceCallController` drives mic capture, WebRTC,
  signaling, and playback.
- **Data-channel contract** (`agent.events`): user transcripts, assistant
  text, agent state, call summaries, and booking confirmations arrive as
  typed events.
- **Barge-in**: `sendBargeIn()` interrupts the agent the instant you start
  talking; the controller also exposes the raw mic stream
  (`localStream`) so you can add your own local speech-onset detection.
- **RTT probes**: built-in ping/pong on the data channel surfaces
  round-trip times via `rttMs`.
- Clean teardown (`end()` / `dispose()`).

## Getting started

Run a voice_forge agent server first (see the voice_forge repo:
`dart run bin/agent_server.dart` in `examples/poc_server` — serves
`ws://host:8765/signal`).

Add the dependency:

```yaml
dependencies:
  voice_forge_flutter: ^0.1.0
```

## Usage

```dart
import 'package:voice_forge_flutter/voice_forge_flutter.dart';

final call = VoiceCallController(
  signalingUrl: 'ws://localhost:8765/signal',
  // iceServers: optional, defaults to Google's public STUN
);

call.phase.listen((p) => print('phase: $p')); // idle/connecting/connected/error
call.events.listen((e) {
  switch (e['type']) {
    case 'user_transcript':
      print('you: ${e['text']}');
    case 'assistant_text':
      print('agent: ${e['text']}');
    case 'agent_state':
      print('state: ${e['state']}'); // idle/listening/thinking/speaking
    case 'summary':
      print('summary: ${e['text']}');
  }
});
call.rttMs.listen((ms) => print('data-channel RTT: ${ms}ms'));

await call.start();     // mic -> agent; agent audio plays automatically
call.sendBargeIn();     // interrupt the agent instantly
await call.send({'event': 'patient_id', 'patient_id': 'PAT-123'});
await call.setMicEnabled(false); // mute without hanging up
await call.end();
```

The `events` stream carries the full voice_forge contract — anything the agent
publishes on `agent.events` (`user_transcript`, `assistant_text`,
`agent_state`, `summary`, `booking_confirmed`, `connected`, …) is forwarded
as-is, and any non-JSON message arrives as `{'type': 'raw', 'text': ...}`.

## Additional information

- Server framework: `voice_forge` (pure Dart)
- Repository: https://github.com/example/voice_forge (set to the real URL
  before the first release)
- License: MIT
