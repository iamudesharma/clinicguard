/// voicepipe POC client — built on the voicepipe_flutter package.
///
/// Connects to a voicepipe server (loopback `server.dart` or the full
/// `agent_server.dart`), sends the real microphone, plays the agent audio,
/// and shows the data-channel event log + RTT.
///
/// Run (server first, from examples/poc_server), then from this folder:
///   flutter run -d chrome
///   flutter run -d chrome --dart-define=AUTO_CALL=true (headless check)
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voicepipe_flutter/voicepipe_flutter.dart';

const _defaultServer = 'ws://127.0.0.1:8765/signal';

void main() => runApp(const PocClientApp());

class PocClientApp extends StatelessWidget {
  const PocClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voicepipe POC client',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const CallScreen(),
    );
  }
}

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _serverController = TextEditingController(text: _defaultServer);
  final _log = <String>[];

  VoiceCallController? _call;
  StreamSubscription<Map<String, dynamic>>? _eventsSub;
  StreamSubscription<int>? _rttSub;
  StreamSubscription<VoiceCallPhase>? _phaseSub;

  // AUTO_CALL=true via --dart-define starts the call without a button tap
  // (used for headless verification runs).
  static const _autoCall = bool.fromEnvironment('AUTO_CALL');

  VoiceCallPhase _phase = VoiceCallPhase.idle;
  String? _lastRtt;
  int _eventsSeen = 0;

  @override
  void initState() {
    super.initState();
    if (_autoCall) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startCall());
    }
  }

  void _append(String line) {
    debugPrint('[poc-client] $line');
    setState(() => _log.insert(0, '$line\n'));
  }

  Future<void> _startCall() async {
    if (_call != null) return;
    final call = VoiceCallController(
      signalingUrl: _serverController.text.trim(),
    );
    _call = call;

    _phaseSub = call.phase.listen((p) {
      debugPrint('[poc-client] phase: $p');
      setState(() => _phase = p);
    });
    _eventsSub = call.events.listen((msg) {
      final t = msg['type'] ?? 'event';
      final text = msg['text'] ?? msg['state'] ?? '';
      _append('$t: $text');
      setState(() => _eventsSeen++);
    });
    _rttSub = call.rttMs.listen((rtt) {
      setState(() => _lastRtt = '$rtt ms');
    });

    try {
      await call.start();
      _append('call started');
    } catch (e) {
      _append('ERROR: $e');
    }
  }

  Future<void> _endCall() async {
    final call = _call;
    _call = null;
    await _eventsSub?.cancel();
    await _rttSub?.cancel();
    await _phaseSub?.cancel();
    if (call != null) {
      await call.end();
      _append('call ended');
    }
  }

  @override
  void dispose() {
    _endCall();
    _serverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('voicepipe POC — client')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _serverController,
              enabled: _phase != VoiceCallPhase.connecting &&
                  _phase != VoiceCallPhase.connected,
              decoration: const InputDecoration(
                labelText: 'Signaling URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _call != null ? null : _startCall,
                    icon: const Icon(Icons.mic),
                    label: const Text('Start call'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _call != null ? _endCall : null,
                    icon: const Icon(Icons.call_end),
                    label: const Text('End'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                Chip(label: Text('state: ${_phase.name}')),
                Chip(label: Text('RTT: ${_lastRtt ?? '-'}')),
                Chip(label: Text('events: $_eventsSeen')),
                if (_call != null)
                  Chip(
                    label: Text('mic: ${_call!.micEnabled ? 'on' : 'off'}'),
                    onDeleted: () async {
                      await _call!.setMicEnabled(!_call!.micEnabled);
                      setState(() {});
                    },
                    deleteIcon: const Icon(Icons.mic_off, size: 16),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView(
                  reverse: true,
                  children: _log
                      .map((l) => Text(
                            l,
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
