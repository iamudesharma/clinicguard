import 'package:flutter/material.dart';

import '../state/call_state.dart';
import '../theme/app_theme.dart';

enum ConversationViewMode { voiceFocus, chatTimeline }

/// Floating frosted-glass call control dock with live audio meter ring,
/// mode toggle (Voice <-> Chat), instant interrupt button, and glowing end call.
class VoiceDock extends StatelessWidget {
  const VoiceDock({
    super.key,
    required this.state,
    required this.viewMode,
    required this.onToggleViewMode,
    this.onBargeIn,
  });

  final CallState state;
  final ConversationViewMode viewMode;
  final VoidCallback onToggleViewMode;
  final VoidCallback? onBargeIn;

  @override
  Widget build(BuildContext context) {
    final isSpeaking = state.agentState == 'speaking';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlassStrong,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.borderGlassStrong),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          if (isSpeaking)
            BoxShadow(
              color: AppColors.fuchsia.withValues(alpha: 0.15),
              blurRadius: 18,
            ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. Microphone Toggle with audio reactive outer ring
          ValueListenableBuilder<double>(
            valueListenable: state.micLevel,
            builder: (context, level, child) {
              final scale = 1.0 + (state.micEnabled ? level * 0.35 : 0.0);
              return Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: state.micEnabled
                        ? AppColors.neonCyan.withValues(alpha: 0.4 + level * 0.6)
                        : AppColors.danger.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                  boxShadow: state.micEnabled && level > 0.05
                      ? [
                          BoxShadow(
                            color: AppColors.neonCyan.withValues(alpha: 0.4 * level),
                            blurRadius: 10 + 10 * level,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: Transform.scale(
                  scale: scale,
                  child: IconButton(
                    onPressed: state.toggleMic,
                    icon: Icon(
                      state.micEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
                      color: state.micEnabled ? AppColors.neonCyan : AppColors.danger,
                    ),
                    tooltip: state.micEnabled ? 'Mute microphone' : 'Unmute microphone',
                    iconSize: 24,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 8),

          // 2. Mode Toggle (Voice Focus <-> Chat Stream)
          IconButton(
            onPressed: onToggleViewMode,
            icon: Icon(
              viewMode == ConversationViewMode.voiceFocus
                  ? Icons.chat_bubble_outline_rounded
                  : Icons.graphic_eq_rounded,
              color: AppColors.ink,
            ),
            tooltip: viewMode == ConversationViewMode.voiceFocus
                ? 'Switch to Chat view'
                : 'Switch to Voice view',
            iconSize: 22,
          ),
          const SizedBox(width: 4),

          // 3. Instant Barge-In / Interrupt Button (active when agent is speaking)
          if (isSpeaking) ...[
            Container(
              decoration: BoxDecoration(
                color: AppColors.auroraFuchsia.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: AppColors.auroraFuchsia.withValues(alpha: 0.5)),
              ),
              child: IconButton(
                onPressed: () {
                  if (onBargeIn != null) {
                    onBargeIn!();
                  } else {
                    // Trigger instant interrupt
                    state.toggleMic();
                    state.toggleMic();
                  }
                },
                icon: const Icon(Icons.front_hand_outlined, color: AppColors.auroraFuchsia),
                tooltip: 'Interrupt assistant',
                iconSize: 20,
              ),
            ),
            const SizedBox(width: 6),
          ],

          // 4. Generate Summary Button (when available)
          if (state.summary == null) ...[
            IconButton(
              onPressed: state.refreshSummary,
              icon: const Icon(Icons.summarize_outlined, color: AppColors.inkMuted),
              tooltip: 'Generate summary',
              iconSize: 22,
            ),
            const SizedBox(width: 6),
          ],

          // 5. Glowing End Call Button
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.coralRed, AppColors.orange],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.coralRed.withValues(alpha: 0.55),
                  blurRadius: 14,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: IconButton(
              onPressed: state.endCall,
              icon: const Icon(Icons.call_end_rounded, color: Colors.white, size: 22),
              tooltip: 'End triage call',
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}
