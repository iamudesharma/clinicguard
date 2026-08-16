import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Frosted-glass surface: backdrop blur + translucent fill + hairline border,
/// optionally wrapped in a colored glow. Base card for the whole redesign.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin,
    this.radius = AppRadius.lg,
    this.blur = 18,
    this.fill = AppColors.surfaceGlass,
    this.borderColor = AppColors.borderGlass,
    this.borderWidth = 1,
    this.glow,
    this.glowOpacity = 0.35,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final double blur;
  final Color fill;
  final Color borderColor;
  final double borderWidth;
  final Color? glow;
  final double glowOpacity;

  @override
  Widget build(BuildContext context) {
    Widget card = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: borderColor, width: borderWidth),
          ),
          child: child,
        ),
      ),
    );

    final glowColor = glow;
    if (glowColor != null) {
      card = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: glowColor.withValues(alpha: glowOpacity),
              blurRadius: 24,
              spreadRadius: 1,
            ),
          ],
        ),
        child: card,
      );
    }

    final m = margin;
    if (m != null) card = Padding(padding: m, child: card);
    return card;
  }
}
