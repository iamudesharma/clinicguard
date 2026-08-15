---
name: data-channel-contract
description: Use when adding, changing, or debugging data-channel messages between the client and the agent — topic agent.events. The contract lives in THREE places that must stay in sync: server/agent.py, app/lib/state/call_state.dart, and voicepipe (packages/voicepipe/lib/src/session/agent_session.dart + examples/poc_server).
---

# agent.events data-channel contract

One shared contract across ClinicGuard (LiveKit) and voicepipe (WebRTC). Topic: `agent.events`. Messages are JSON. Keep all three implementations in sync — they already drift once (`summary_error`).

## Server → client events

| type              | payload                         | ClinicGuard server          | voicepipe                        | Flutter app (`call_state.dart`) |
| ----------------- | ------------------------------- | --------------------------- | -------------------------------- | ------------------------------- |
| `user_transcript` | `{text, is_final, language}`    | agent.py ~203               | agent_session.dart ~129          | handled ~185                    |
| `assistant_text`  | `{text, item_id}`               | agent.py ~224               | agent_session.dart ~139          | handled ~193                    |
| `agent_state`     | `{state}` idle/listening/thinking/speaking | agent.py ~229      | agent_session.dart ~82           | handled ~200                    |
| `summary`         | `{summary}`                     | agent.py (event relay)      | — (not in voicepipe yet)         | handled ~203                    |
| `summary_error`   | `{error}`                       | agent.py ~309               | —                                | **NOT handled** — known drift   |

## Client → server

`{"event":"barge_in"}` on the same topic for instant interrupt:
- ClinicGuard app: `app/lib/vad/barge_in_controller.dart` (~line 90); server side: `agent.py` `_on_data_received` (~line 240).
- voicepipe: `packages/voicepipe_flutter/lib/src/voice_call_controller.dart` `sendBargeIn()`; server side `examples/poc_server/bin/agent_server.dart` (~line 67).

## When changing the contract

1. Update the table's row in ALL three places (add `summary_error` handling to `call_state.dart` first if you touch summaries).
2. ClinicGuard: app switch at `app/lib/state/call_state.dart` ~184-206; server publish points in `agent.py` EventRelay.
3. voicepipe: `agent_session.dart` publish points + `agent_server.dart`/`agent_self_test.dart` if the loop or test asserts on events.
4. Extend `agent_self_test.dart` event assertions if the new event should be asserted.
5. Verify with the `verify-stack` skill (voicepipe self-test asserts `user_transcript`/`assistant_text`/`agent_state` counts and states).