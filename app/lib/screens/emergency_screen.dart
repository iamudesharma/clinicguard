import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';

/// Displays emergency information when the triage agent detects a medical
/// emergency. Shows urgency banner, clinical reasoning, emergency numbers,
/// nearest hospital details, and action buttons.
class EmergencyScreen extends StatelessWidget {
  const EmergencyScreen({super.key, required this.emergencyData});

  /// Emergency payload from the triage agent containing [urgency_level],
  /// [reason], and [nearest_hospital] details.
  final Map<String, dynamic> emergencyData;

  @override
  Widget build(BuildContext context) {
    final reason = emergencyData['reason'] as String? ?? '';
    final hospital =
        emergencyData['nearest_hospital'] as Map<String, dynamic>? ?? {};

    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _EmergencyBanner(),
              const SizedBox(height: 20),
              _ClinicalReason(reason: reason),
              const SizedBox(height: 16),
              _EmergencyNumbers(),
              const SizedBox(height: 16),
              _HospitalInfo(hospital: hospital),
              const SizedBox(height: 24),
              _ActionButtons(mapsUrl: hospital['maps_url'] as String?),
            ],
          ),
        ),
      ),
    );
  }
}

/// Red emergency banner at the top of the screen.
class _EmergencyBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.triageEmergency,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: [
          BoxShadow(
            color: AppColors.triageEmergency.withValues(alpha: 0.35),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: const Column(
        children: [
          Icon(Icons.warning_rounded, color: Colors.white, size: 48),
          SizedBox(height: 12),
          Text(
            'This is a medical emergency',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Displays the clinical reasoning for the emergency classification.
class _ClinicalReason extends StatelessWidget {
  const _ClinicalReason({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    if (reason.isEmpty) return const SizedBox.shrink();

    return GlassCard(
      glow: AppColors.triageEmergency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Clinical Reason',
            style: TextStyle(
              color: AppColors.inkMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            reason,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 16,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows emergency telephone numbers for EU and US.
class _EmergencyNumbers extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GlassCard(
      glow: AppColors.coralRed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Emergency Numbers',
            style: TextStyle(
              color: AppColors.inkMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          _NumberRow(label: '112', region: 'EU'),
          const SizedBox(height: 8),
          _NumberRow(label: '911', region: 'US'),
        ],
      ),
    );
  }
}

/// Single row displaying an emergency number and its region.
class _NumberRow extends StatelessWidget {
  const _NumberRow({required this.label, required this.region});

  final String label;
  final String region;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.phone_rounded, color: AppColors.coralRed, size: 20),
        const SizedBox(width: 12),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '($region)',
          style: const TextStyle(color: AppColors.inkMuted, fontSize: 14),
        ),
      ],
    );
  }
}

/// Displays nearest hospital information from the emergency data.
class _HospitalInfo extends StatelessWidget {
  const _HospitalInfo({required this.hospital});

  final Map<String, dynamic> hospital;

  @override
  Widget build(BuildContext context) {
    final name = hospital['name'] as String? ?? '';
    final address = hospital['address'] as String? ?? '';
    if (name.isEmpty) return const SizedBox.shrink();

    return GlassCard(
      glow: AppColors.triageEmergency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Nearest Hospital',
            style: TextStyle(
              color: AppColors.inkMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (address.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              address,
              style: const TextStyle(color: AppColors.inkMuted, fontSize: 14),
            ),
          ],
        ],
      ),
    );
  }
}

/// Action buttons for calling emergency services, opening maps, and returning.
class _ActionButtons extends StatelessWidget {
  const _ActionButtons({this.mapsUrl});

  final String? mapsUrl;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActionButton(
          label: 'Open in Maps',
          icon: Icons.map_rounded,
          color: AppColors.cyan,
          onTap: mapsUrl != null ? () => _launchUrl(mapsUrl!) : null,
        ),
        const SizedBox(height: 12),
        _ActionButton(
          label: 'Call Emergency',
          icon: Icons.phone_rounded,
          color: AppColors.triageEmergency,
          onTap: () => _launchUrl('tel:911'),
        ),
        const SizedBox(height: 12),
        _ActionButton(
          label: "I've called \u2014 return to triage",
          icon: Icons.arrow_back_rounded,
          color: AppColors.inkMuted,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }
}

/// A single action button with icon, label, and accent color.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
