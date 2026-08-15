import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/call_state.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<CallState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('ClinicGuard Triage'),
        backgroundColor: Colors.teal.shade700,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _StatusBar(state: state),
            const SizedBox(height: 12),
            Expanded(child: _TranscriptList(state: state)),
            _SummaryCard(state: state),
            _ControlBar(state: state),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final CallState state;
  const _StatusBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state.agentState) {
      'listening' => ('Agent is listening', Colors.teal),
      'thinking' => ('Agent is thinking', Colors.orange),
      'speaking' => ('Agent is speaking', Colors.indigo),
      _ => (switch (state.phase) {
          CallPhase.connecting => 'Connecting…',
          CallPhase.error => state.error,
          _ => 'Tap the mic to start triage',
        }, Colors.blueGrey),
    };

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 12, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w600, color: color),
            ),
          ),
          if (state.phase == CallPhase.connected)
            Text(
              state.roomId,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _TranscriptList extends StatelessWidget {
  final CallState state;
  const _TranscriptList({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.transcript.isEmpty) {
      return Center(
        child: Text(
          'Your conversation with the triage assistant\nwill appear here (English / हिन्दी)',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: state.transcript.length,
      itemBuilder: (context, i) {
        final line = state.transcript[i];
        final isUser = line.role == 'user';
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: isUser
                  ? Colors.teal.shade100
                  : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(line.text, style: const TextStyle(fontSize: 15)),
          ),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final CallState state;
  const _SummaryCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.summary;
    if (s == null) return const SizedBox.shrink();

    final urgency = (s['urgency_level'] ?? 'low').toString();
    final urgencyColor = switch (urgency) {
      'emergency' => Colors.red,
      'high' => Colors.deepOrange,
      'medium' => Colors.amber.shade800,
      _ => Colors.green,
    };

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: urgencyColor, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.medical_information, color: urgencyColor),
              const SizedBox(width: 8),
              const Text('EHR Summary',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: urgencyColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  urgency.toUpperCase(),
                  style: TextStyle(
                    color: urgencyColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${s['chief_complaint'] ?? ''}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text('${s['patient_name'] ?? ''} · ${s['patient_age'] ?? ''}'),
          const SizedBox(height: 8),
          for (final action in (s['recommended_actions'] as List? ?? []))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('• $action'),
            ),
        ],
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  final CallState state;
  const _ControlBar({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (state.phase != CallPhase.idle) ...[
            IconButton.filledTonal(
              onPressed: state.micEnabled ? state.toggleMic : state.toggleMic,
              icon: Icon(
                state.micEnabled ? Icons.mic : Icons.mic_off,
                color: state.micEnabled ? Colors.teal : Colors.red,
              ),
              tooltip: 'Toggle microphone',
              iconSize: 28,
            ),
            const SizedBox(width: 12),
            IconButton.filledTonal(
              onPressed: state.summary == null ? state.refreshSummary : null,
              icon: const Icon(Icons.summarize_outlined),
              tooltip: 'Generate summary',
              iconSize: 28,
            ),
            const SizedBox(width: 12),
            IconButton.filled(
              onPressed: state.endCall,
              icon: const Icon(Icons.call_end, color: Colors.white),
              style: IconButton.styleFrom(backgroundColor: Colors.red),
              tooltip: 'End call',
              iconSize: 28,
            ),
          ] else
            FilledButton.icon(
              onPressed: state.startCall,
              icon: const Icon(Icons.call),
              label: const Text('Start triage call'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.teal.shade700,
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
              ),
            ),
        ],
      ),
    );
  }
}
