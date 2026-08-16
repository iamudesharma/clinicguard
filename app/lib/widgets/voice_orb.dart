import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Orb animation modes, mirroring the agent's `agent_state` data-channel
/// values ('idle' | 'listening' | 'thinking' | 'speaking').
enum OrbMode { idle, listening, thinking, speaking }

OrbMode orbModeFromAgentState(String state) => switch (state) {
      'listening' => OrbMode.listening,
      'thinking' => OrbMode.thinking,
      'speaking' => OrbMode.speaking,
      _ => OrbMode.idle,
    };

List<Color> _modeColors(OrbMode mode) => switch (mode) {
      OrbMode.listening => const [
          AppColors.neonCyan,
          AppColors.electricTeal,
          AppColors.teal,
        ],
      OrbMode.thinking => const [
          AppColors.amberGlow,
          AppColors.plasmaViolet,
          AppColors.auroraFuchsia,
        ],
      OrbMode.speaking => const [
          AppColors.auroraFuchsia,
          AppColors.neonCyan,
          AppColors.plasmaViolet,
          AppColors.electricTeal,
        ],
      OrbMode.idle => const [
          AppColors.cyan,
          AppColors.violet,
          AppColors.blueGrey,
        ],
    };

/// State-of-the-art Gemini Live & ChatGPT-inspired glowing fluid voice orb.
///
/// Features:
/// * Idle     — Soft iridescent breathing with drifting inner nebula core
/// * Listening — Real-time audio-reactive fluid perimeter wave deformation & ripples
/// * Thinking — Dual-conic rotating aurora sweep + orbiting star sparkles
/// * Speaking — High-energy harmonic wave morphing + radiant bloom aura
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.mode,
    this.level,
    this.size = 220,
    this.onTap,
  });

  final OrbMode mode;

  /// Live audio level 0..1 (web mic tap or simulated audio RMS).
  final ValueListenable<double>? level;

  final double size;
  final VoidCallback? onTap;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _level = 0;
  double _levelTarget = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    widget.level?.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(covariant VoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level != widget.level) {
      oldWidget.level?.removeListener(_onLevel);
      widget.level?.addListener(_onLevel);
      _level = _levelTarget;
    }
  }

  void _onLevel() {
    _levelTarget = widget.level?.value.clamp(0.0, 1.0) ?? 0;
    // Smooth interpolation to prevent jittering per audio frame
    _level += (_levelTarget - _level) * 0.40;
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
        final t = reduceMotion ? 0.25 : _controller.value;
        final orb = CustomPaint(
          painter: _FluidOrbPainter(
            t: t,
            mode: widget.mode,
            level: _level,
            size: widget.size,
          ),
          size: Size.square(widget.size),
        );

        final gesture = widget.onTap == null
            ? orb
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                child: orb,
              );

        return Semantics(
          button: widget.onTap != null,
          label: switch (widget.mode) {
            OrbMode.listening => 'Agent is listening',
            OrbMode.thinking => 'Agent is thinking',
            OrbMode.speaking => 'Agent is speaking',
            OrbMode.idle => 'Voice orb — tap to start triage',
          },
          child: gesture,
        );
      },
    );
  }
}

class _FluidOrbPainter extends CustomPainter {
  _FluidOrbPainter({
    required this.t,
    required this.mode,
    required this.level,
    required this.size,
  });

  final double t;
  final OrbMode mode;
  final double level;
  final double size;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final colors = _modeColors(mode);
    final center = Offset(size / 2, size / 2);

    // 1. Organic Breathing & Dynamic Amplitude factors
    final breathe = 1.0 + 0.05 * math.sin(2 * math.pi * t);
    
    // Dynamic amplitude based on mode + mic level
    final double amp;
    if (mode == OrbMode.speaking) {
      amp = level > 0.01
          ? (0.85 + 0.55 * level + 0.15 * math.sin(4 * math.pi * t))
          : (0.90 + 0.18 * math.sin(2 * math.pi * t * 2));
    } else if (mode == OrbMode.listening) {
      amp = level > 0.01
          ? (0.88 + 0.45 * level)
          : (0.95 + 0.08 * math.sin(2 * math.pi * t * 1.5));
    } else if (mode == OrbMode.thinking) {
      amp = 0.96 + 0.08 * math.sin(2 * math.pi * t * 3);
    } else {
      amp = 1.0;
    }

    final coreR = size * 0.28 * breathe * amp;

    // 2. Atmospheric Multi-Layer Bloom Glow
    final glowPaint1 = Paint()
      ..shader = RadialGradient(
        colors: [
          colors.first.withValues(alpha: 0.50 * amp.clamp(0.8, 1.4)),
          colors[1 % colors.length].withValues(alpha: 0.20),
          Colors.transparent,
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: size * 0.52))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22);
    canvas.drawCircle(center, size * 0.52, glowPaint1);

    final glowPaint2 = Paint()
      ..shader = RadialGradient(
        colors: [
          colors.last.withValues(alpha: 0.35),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: size * 0.40))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawCircle(center, size * 0.40, glowPaint2);

    // 3. Audio Ripple Wave Rings (Listening mode)
    if (mode == OrbMode.listening) {
      for (var i = 0; i < 3; i++) {
        final ringT = (t + i / 3.0) % 1.0;
        final ringRadius = coreR * (1.1 + ringT * 1.4);
        final ringAlpha = ((1.0 - ringT) * (0.6 + 0.4 * level)).clamp(0.0, 1.0);
        
        final ringPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0 * (1.0 - ringT * 0.5)
          ..color = colors[i % colors.length].withValues(alpha: ringAlpha);
        canvas.drawCircle(center, ringRadius, ringPaint);
      }
    }

    // 4. Rotating Conic Sweep Rings (Thinking & Speaking modes)
    if (mode == OrbMode.thinking || mode == OrbMode.speaking) {
      final sweepAngle = 2 * math.pi * (mode == OrbMode.thinking ? t * 1.5 : t * 0.8);
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: 2 * math.pi,
          transform: GradientRotation(sweepAngle),
          colors: [
            colors[0].withValues(alpha: 0.0),
            colors[0].withValues(alpha: 0.8),
            colors[colors.length - 1].withValues(alpha: 0.9),
            colors[0].withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.25, 0.65, 0.9],
        ).createShader(Rect.fromCircle(center: center, radius: coreR * 1.35))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      canvas.drawCircle(center, coreR * 1.28, sweepPaint);
    }

    // 5. Dynamic Fluid Perimeter Shape (Per-vertex sine wave displacement)
    final path = Path();
    const int segments = 72;
    final double angleStep = (2 * math.pi) / segments;

    for (var i = 0; i <= segments; i++) {
      final theta = i * angleStep;
      
      // Harmonic wave displacement
      double waveDisp = 0.0;
      if (mode == OrbMode.speaking || mode == OrbMode.listening) {
        final waveFactor = (mode == OrbMode.speaking ? 1.4 : 0.8) * (level > 0.02 ? level * 2.0 : 0.3);
        waveDisp = math.sin(theta * 4 + 2 * math.pi * t * 3) * (coreR * 0.08 * waveFactor) +
                   math.cos(theta * 6 - 2 * math.pi * t * 2) * (coreR * 0.05 * waveFactor);
      } else if (mode == OrbMode.thinking) {
        waveDisp = math.sin(theta * 3 + 2 * math.pi * t * 4) * (coreR * 0.06);
      }

      final r = coreR + waveDisp;
      final x = center.dx + r * math.cos(theta);
      final y = center.dy + r * math.sin(theta);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();

    // 6. Fluid Core Shader
    final coreGradient = RadialGradient(
      center: Alignment(
        -0.35 + 0.15 * math.sin(2 * math.pi * t),
        -0.40 + 0.15 * math.cos(2 * math.pi * t),
      ),
      radius: 0.95,
      colors: [
        Colors.white.withValues(alpha: 0.98),
        colors.first,
        colors[1 % colors.length],
        colors.last,
      ],
      stops: const [0.0, 0.28, 0.65, 1.0],
    );

    canvas.drawPath(
      path,
      Paint()..shader = coreGradient.createShader(Rect.fromCircle(center: center, radius: coreR)),
    );

    // 7. Specular Lens Highlight & Inner Rim Light
    final highlightOffset = center - Offset(coreR * 0.36, coreR * 0.40);
    canvas.drawCircle(
      highlightOffset,
      coreR * 0.32,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    // 8. Orbiting Star Sparkles (Thinking & Speaking modes)
    if (mode == OrbMode.thinking || mode == OrbMode.speaking) {
      final int sparkleCount = mode == OrbMode.thinking ? 6 : 4;
      for (var i = 0; i < sparkleCount; i++) {
        final speed = mode == OrbMode.thinking ? 1.8 : 1.0;
        final phase = i * (2 * math.pi / sparkleCount);
        final angle = 2 * math.pi * t * speed + phase;
        final sparkleDist = coreR * (1.35 + 0.18 * math.sin(2 * math.pi * t * 2 + i));
        
        final pos = center + Offset(math.cos(angle), math.sin(angle)) * sparkleDist;
        final sparkleAlpha = (0.4 + 0.6 * (0.5 + 0.5 * math.sin(4 * math.pi * t + i * 2.0))).clamp(0.0, 1.0);
        final sparkleRadius = 2.5 + 1.5 * math.sin(2 * math.pi * t * 3 + i);

        canvas.drawCircle(
          pos,
          sparkleRadius + 2.0,
          Paint()
            ..color = colors[i % colors.length].withValues(alpha: sparkleAlpha * 0.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
        canvas.drawCircle(
          pos,
          sparkleRadius,
          Paint()..color = Colors.white.withValues(alpha: sparkleAlpha),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FluidOrbPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.mode != mode ||
      oldDelegate.level != level ||
      oldDelegate.size != size;
}
