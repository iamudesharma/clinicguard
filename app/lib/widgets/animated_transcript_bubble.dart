import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'voice_wave_visualizer.dart';

/// Next-gen transcript message bubble with glowing glass aesthetics,
/// audio activity wave indicator, triage badges, and spring pop-in.
class TranscriptBubble extends StatefulWidget {
  const TranscriptBubble({
    super.key,
    required this.text,
    required this.isUser,
    this.animate = true,
    this.isSpeaking = false,
    this.language,
    this.maxWidth = 340,
  });

  final String text;
  final bool isUser;
  final bool animate;
  final bool isSpeaking;
  final String? language;
  final double maxWidth;

  @override
  State<TranscriptBubble> createState() => _TranscriptBubbleState();
}

class _TranscriptBubbleState extends State<TranscriptBubble> {
  bool _copied = false;

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.isUser;

    // Detect clinical triage urgency cues in assistant text
    final textLower = widget.text.toLowerCase();
    final isEmergency = !isUser && (textLower.contains('emergency') || textLower.contains('911') || textLower.contains('immediately'));
    final isUrgent = !isUser && !isEmergency && (textLower.contains('urgent') || textLower.contains('warning') || textLower.contains('fever'));

    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      decoration: BoxDecoration(
        gradient: isUser
            ? AppGradients.userBubble
            : (isEmergency
                ? const LinearGradient(
                    colors: [Color(0x33FF2A6D), Color(0x180D1526)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : AppGradients.assistantBubble),
        color: isUser ? null : AppColors.surfaceGlassStrong,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadius.md),
          topRight: const Radius.circular(AppRadius.md),
          bottomLeft: Radius.circular(isUser ? AppRadius.md : 4),
          bottomRight: Radius.circular(isUser ? 4 : AppRadius.md),
        ),
        border: Border.all(
          color: isEmergency
              ? AppColors.triageEmergency.withValues(alpha: 0.6)
              : (isUrgent
                  ? AppColors.triageUrgent.withValues(alpha: 0.45)
                  : (isUser
                      ? AppColors.neonCyan.withValues(alpha: 0.5)
                      : AppColors.borderGlassStrong)),
          width: isEmergency ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: isEmergency
                ? AppColors.triageEmergency.withValues(alpha: 0.25)
                : (isUser
                    ? AppColors.cyan.withValues(alpha: 0.22)
                    : (widget.isSpeaking ? AppColors.violet.withValues(alpha: 0.25) : Colors.black.withValues(alpha: 0.15))),
            blurRadius: isUser || widget.isSpeaking ? 16 : 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Header tag row (role, language, audio wave)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isUser ? Icons.account_circle_outlined : Icons.health_and_safety_outlined,
                  size: 14,
                  color: isUser ? Colors.white70 : AppColors.neonCyan,
                ),
                const SizedBox(width: 5),
                Text(
                  isUser ? 'You' : 'ClinicGuard AI',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isUser ? Colors.white70 : AppColors.inkMuted,
                  ),
                ),
                if (widget.language != null && widget.language!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.language!.toUpperCase(),
                      style: const TextStyle(fontSize: 9, color: Colors.white70, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
                if (widget.isSpeaking) ...[
                  const SizedBox(width: 8),
                  const VoiceWaveVisualizer(
                    width: 28,
                    height: 12,
                    barCount: 4,
                    color: AppColors.auroraFuchsia,
                    secondaryColor: AppColors.neonCyan,
                  ),
                ],
                if (isEmergency) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.triageEmergency.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(color: AppColors.triageEmergency.withValues(alpha: 0.5)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 10, color: AppColors.triageEmergency),
                        SizedBox(width: 3),
                        Text(
                          'EMERGENCY',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: AppColors.triageEmergency,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Bubble Text Content
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: Text(
              widget.text,
              style: TextStyle(
                fontSize: 15,
                height: 1.4,
                color: isUser ? Colors.white : AppColors.ink,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          // Actions bar (Copy action)
          if (!isUser && widget.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: _copyToClipboard,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _copied ? Icons.check : Icons.copy_rounded,
                            size: 12,
                            color: _copied ? AppColors.success : AppColors.inkFaint,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _copied ? 'Copied' : 'Copy',
                            style: TextStyle(
                              fontSize: 10,
                              color: _copied ? AppColors.success : AppColors.inkFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    final aligned = Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: bubble,
    );

    if (!widget.animate) return aligned;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutBack,
      builder: (context, v, child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.88 + 0.12 * v,
          alignment: isUser ? Alignment.bottomRight : Alignment.bottomLeft,
          child: child,
        ),
      ),
      child: aligned,
    );
  }
}
