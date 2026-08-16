import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class GlowNavDestination {
  const GlowNavDestination({
    required this.icon,
    required this.label,
    this.selectedIcon,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;
}

/// Floating glass bottom navigation bar with an animated aurora selection
/// pill — the Gemini-Live-style replacement for `NavigationBar`.
class GlowNavBar extends StatelessWidget {
  const GlowNavBar({
    super.key,
    required this.index,
    required this.onChanged,
    required this.destinations,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final List<GlowNavDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.lg),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: AppColors.surfaceGlassStrong,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: AppColors.borderGlass),
            ),
            child: Row(
              children: [
                for (var i = 0; i < destinations.length; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: _NavItem(
                      destination: destinations[i],
                      selected: i == index,
                      onTap: () => onChanged(i),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final GlowNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          gradient: selected ? AppGradients.navPill : null,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppColors.cyan.withValues(alpha: 0.22),
                    blurRadius: 16,
                    spreadRadius: 0,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? (destination.selectedIcon ?? destination.icon)
                  : destination.icon,
              size: 22,
              color: selected ? AppColors.cyan : AppColors.inkMuted,
            ),
            const SizedBox(height: 2),
            Text(
              destination.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.ink : AppColors.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
