import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Slow-drifting aurora blobs behind the whole app (Gemini-Live style).
/// Pure radial gradients — no blur filters — cheap to repaint each frame.
/// Respects the system "reduce motion" setting (static aurora then).
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, this.child, this.animate = true});

  final Widget? child;
  final bool animate;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant AuroraBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate) {
      if (widget.animate) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final t = reduceMotion ? 0.25 : _controller.value;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: AppColors.canvas),
            _Blob(
              t: t,
              size: w * 1.15,
              color: AppColors.violet,
              phase: 0.0,
              cx: w * 0.15,
              cy: h * 0.12,
              drift: 0.08,
            ),
            _Blob(
              t: t,
              size: w * 1.0,
              color: AppColors.teal,
              phase: 1.2,
              cx: w * 0.85,
              cy: h * 0.30,
              drift: 0.06,
            ),
            _Blob(
              t: t,
              size: w * 1.1,
              color: AppColors.cyan,
              phase: 2.4,
              cx: w * 0.50,
              cy: h * 0.95,
              drift: 0.07,
            ),
            // Vignette: darken the edges so the center feels luminous.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 1.2,
                  colors: [
                    Colors.transparent,
                    AppColors.canvas.withValues(alpha: 0.55),
                  ],
                  stops: const [0.55, 1.0],
                ),
              ),
            ),
            if (widget.child != null) widget.child!,
          ],
        );
      },
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({
    required this.t,
    required this.size,
    required this.color,
    required this.phase,
    required this.cx,
    required this.cy,
    required this.drift,
  });

  final double t;
  final double size;
  final Color color;
  final double phase;
  final double cx;
  final double cy;
  final double drift;

  @override
  Widget build(BuildContext context) {
    final angle = 2 * math.pi * (t + phase);
    final x = cx + math.sin(angle) * size * drift;
    final y = cy + math.cos(angle * 1.3) * size * drift * 0.8;
    final breathe = 1.0 + 0.06 * math.sin(2 * math.pi * t + phase * 2);

    return Positioned(
      left: x - size / 2,
      top: y - size / 2,
      child: RepaintBoundary(
        child: Transform.scale(
          scale: breathe,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                radius: 0.72,
                colors: [
                  color.withValues(alpha: 0.26),
                  color.withValues(alpha: 0.10),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
