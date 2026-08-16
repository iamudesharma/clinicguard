## 0.1.0

* Renamed from `voicepipe_flutter` to `voice_forge_flutter` (same package,
  new brand; pairs with the `voice_forge` framework).
* Initial release. `VoiceCallController`: mic → WebRTC → voice_forge agent.
* `agent.events` data-channel contract (`user_transcript`, `assistant_text`,
  `agent_state`, `summary`, `booking_confirmed`, `connected`, `raw`).
* Instant barge-in via `sendBargeIn()`.
* Data-channel RTT pings surfaced through `rttMs`.
* Clean `end()` / `dispose()` teardown.
