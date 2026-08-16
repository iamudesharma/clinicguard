import 'package:flutter/material.dart';

import 'package:voice_forge_flutter/voice_forge_flutter.dart';

/// Minimal voice_forge_flutter usage: one button that starts a call to a
/// voice_forge agent server (ws://host:8765/signal) and prints the
/// `agent.events` data-channel contract.
void main() {
  runApp(const MaterialApp(home: _CallScreen()));
}

class _CallScreen extends StatefulWidget {
  const _CallScreen();

  @override
  State<_CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<_CallScreen> {
  final VoiceCallController _call = VoiceCallController(
    signalingUrl: 'ws://localhost:8765/signal',
  );
  bool _inCall = false;

  @override
  void initState() {
    super.initState();
    _call.events.listen((e) {
      debugPrint('agent.events: ${e['type']}: ${e['text'] ?? e}');
    });
    _call.phase.listen((p) {
      debugPrint('phase: $p');
    });
  }

  Future<void> _toggle() async {
    if (_inCall) {
      await _call.end();
    } else {
      await _call.start();
    }
    if (mounted) setState(() => _inCall = !_inCall);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('voice_forge_flutter example')),
      body: Center(
        child: FilledButton.icon(
          onPressed: _toggle,
          icon: Icon(_inCall ? Icons.call_end : Icons.call),
          label: Text(_inCall ? 'End call' : 'Start call'),
        ),
      ),
    );
  }
}
