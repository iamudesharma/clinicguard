import 'package:flutter/material.dart';

import '../services/care_card.dart';
import '../theme/app_theme.dart';
import 'glass_card.dart';
import 'gradient_text.dart';

/// Next-gen Glass EHR triage summary card with urgency-colored glow,
/// structured triage tags, and clinical recommendation list.
class SummaryCard extends StatelessWidget {
  final Map<String, dynamic> summary;
  final VoidCallback? onShare;

  const SummaryCard({super.key, required this.summary, this.onShare});

  @override
  Widget build(BuildContext context) {
    final urgency = (summary['urgency_level'] ?? 'low').toString().toLowerCase();
    final (urgencyColor, urgencyIcon, urgencyLabel) = switch (urgency) {
      'emergency' => (AppColors.triageEmergency, Icons.emergency, 'EMERGENCY'),
      'high' => (AppColors.orange, Icons.warning_amber_rounded, 'HIGH PRIORITY'),
      'medium' => (AppColors.amberGlow, Icons.info_outline, 'MODERATE PRIORITY'),
      _ => (AppColors.electricTeal, Icons.check_circle_outline, 'ROUTINE'),
    };

    final patientName = (summary['patient_name'] ?? '').toString();
    final patientAge = (summary['patient_age'] ?? '').toString();
    final patientSex = (summary['patient_sex'] ?? '').toString();
    final patientLine = [patientName, patientAge, patientSex]
        .where((v) => v.isNotEmpty)
        .join(' · ');

    final raw = summary['recommended_actions'];
    final actions = raw is List
        ? raw.cast<String>()
        : (summary['recommendation'] != null
            ? [(summary['recommendation']!).toString()]
            : <String>[]);

    final chiefComplaint = (summary['chief_complaint'] ?? '').toString();

    return GlassCard(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      glow: urgencyColor,
      glowOpacity: 0.32,
      borderColor: urgencyColor.withValues(alpha: 0.55),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: urgencyColor.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.medical_services_outlined, color: urgencyColor, size: 18),
              ),
              const SizedBox(width: AppSpacing.sm),
              const GradientText(
                'Clinical Triage Summary',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: urgencyColor.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(
                    color: urgencyColor.withValues(alpha: 0.6),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: urgencyColor.withValues(alpha: 0.25),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(urgencyIcon, size: 12, color: urgencyColor),
                    const SizedBox(width: 4),
                    Text(
                      urgencyLabel,
                      style: TextStyle(
                        color: urgencyColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 10,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (chiefComplaint.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              chiefComplaint,
              style: const TextStyle(
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
                fontSize: 15,
                height: 1.3,
              ),
            ),
          ],
          if (patientLine.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                const Icon(Icons.person_outline, size: 14, color: AppColors.inkMuted),
                const SizedBox(width: 4),
                Text(
                  patientLine,
                  style: const TextStyle(color: AppColors.inkMuted, fontSize: 13),
                ),
              ],
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.surfaceGlass,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: AppColors.borderGlass),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Recommended Care Steps:',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppColors.inkMuted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final action in actions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.arrow_right, size: 16, color: urgencyColor),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Text(
                              action,
                              style: const TextStyle(
                                color: AppColors.ink,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => CareCardService.shareText(summary),
                  icon: const Icon(Icons.share_outlined, size: 16),
                  label: const Text('Share Summary', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.inkMuted,
                    side: BorderSide(color: AppColors.borderGlass),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => CareCardService.sharePdf(summary),
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
                  label: const Text('Export PDF', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.inkMuted,
                    side: BorderSide(color: AppColors.borderGlass),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
