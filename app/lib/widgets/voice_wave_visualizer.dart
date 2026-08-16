import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Audio-reactive dynamic waveform / frequency bar visualizer.
/// Can be rendered as vertical bars or continuous fluid wave ribbon.
class VoiceWaveVisualizer extends StatefulWidget {
  const VoiceWaveVisualizer({
    super.key,
    this.barCount = 5,
    this.height = 24,
    this.width = 44,
    this.color = AppColors.neonCyan,
    this.secondaryColor = AppColors.violet,
    this.level,
    this.active = true,
  });

  final int barCount;
  final double height;
  final double width;
  final Color color;
  final Color secondaryColor;
  final ValueListenable<double>? level;
  final bool active;

  @override
  State<VoiceWaveVisualizer> createState() => _VoiceWaveVisualizerState();
}

class _VoiceWaveVisualizerState extends State<VoiceWaveVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _smoothLevel = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    if (widget.active) _controller.repeat();
    widget.level?.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(covariant VoiceWaveVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
    if (oldWidget.level != widget.level) {
      oldWidget.level?.removeListener(_onLevel);
      widget.level?.addListener(_onLevel);
    }
  }

  void _onLevel() {
    final target = widget.level?.value.clamp(0.0, 1.0) ?? 0.0;
    _smoothLevel += (target - _smoothLevel) * 0.4;
  }

  @override
  void dispose() {
    widget.level?.removeListener(_onLevel);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = (reduceMotion || !widget.active) ? 0.3 : _controller.value;
        return CustomPaint(
          size: Size(widget.width, widget.height),
          painter: _WaveBarsPainter(
            t: t,
            barCount: widget.barCount,
            active: widget.active,
            level: _smoothLevel,
            color: widget.color,
            secondaryColor: widget.secondaryColor,
          ),
        );
      },
    );
  }
}

class _WaveBarsPainter extends CustomPainter {
  const _WaveBarsPainter({
    required this.t,
    required this.barCount,
    required this.active,
    required this.level,
    required this.color,
    required this.secondaryColor,
  });

  final double t;
  final int barCount;
  final bool active;
  final double level;
  final Color color;
  final Color secondaryColor;

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = size.width / (barCount * 1.8);
    final spacing = (size.width - (barCount * barWidth)) / (barCount - 1).clamp(1, 99);

    for (var i = 0; i < barCount; i++) {
      final x = i * (barWidth + spacing);
      final phase = i * (math.pi / barCount);
      
      // Calculate animated height
      double heightFactor;
      if (!active) {
        heightFactor = 0.2;
      } else if (level > 0.02) {
        // Voice reactive with sine wave variance
        final voiceWave = 0.3 + 0.7 * math.sin(2 * math.pi * t * 2 + phase).abs();
        heightFactor = (0.2 + (level * 1.5 * voiceWave)).clamp(0.15, 1.0);
      } else {
        // Procedural idling rhythmic wave
        heightFactor = 0.25 + 0.65 * math.sin(2 * math.pi * t + phase).abs();
      }

      final barHeight = (size.height * heightFactor).clamp(3.0, size.height);
      final top = (size.height - barHeight) / 2;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, top, barWidth, barHeight),
        Radius.circular(barWidth / 2),
      );

      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color,
            Color.lerp(color, secondaryColor, i / barCount) ?? secondaryColor,
          ],
        ).createShader(rect.outerRect);

      // Glow shadow
      if (active) {
        canvas.drawRRect(
          rect,
          Paint()
            ..color = color.withValues(alpha: 0.35 * heightFactor)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }

      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveBarsPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.level != level ||
      oldDelegate.active != active ||
      oldDelegate.color != color;
}
