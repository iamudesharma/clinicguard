import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Primary CTA: gradient fill + outer glow, pill or rounded shape.
class GlowButton extends StatelessWidget {
  const GlowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.gradient = AppGradients.aurora,
    this.glow,
    this.radius = AppRadius.pill,
    this.padding = const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
    this.loading = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Gradient gradient;
  final Color? glow;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool loading;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final canTap = enabled && !loading && onPressed != null;
    final glowColor = glow ?? AppColors.cyan;

    return Opacity(
      opacity: canTap ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: gradient,
          boxShadow: [
            BoxShadow(
              color: glowColor.withValues(alpha: 0.45),
              blurRadius: 24,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
          child: InkWell(
            borderRadius: BorderRadius.circular(radius),
            onTap: canTap ? onPressed : null,
            child: Padding(
              padding: padding,
              child: loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.onGradient,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: AppColors.onGradient, size: 20),
                          const SizedBox(width: 10),
                        ],
                        Text(
                          label,
                          style: const TextStyle(
                            color: AppColors.onGradient,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
