import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'glass_card.dart';
import 'urgency_badge.dart';

/// Glass-styled card for a single session in the clinician queue dashboard.
class QueueCard extends StatelessWidget {
  const QueueCard({
    super.key,
    required this.item,
    this.currentUserId = '',
    this.onClaim,
    this.onUnclaim,
  });

  /// Session map from `GET /queue`.
  final Map<String, dynamic> item;

  /// ID of the currently signed-in clinician.
  final String currentUserId;

  /// Called when the clinician claims this session.
  final VoidCallback? onClaim;

  /// Called when the clinician unclaims this session.
  final VoidCallback? onUnclaim;

  String get _patientName => (item['patient_name'] ?? 'Guest').toString();

  String get _complaint =>
      (item['chief_complaint'] ?? item['reason'] ?? '').toString();

  String get _urgency =>
      (item['urgency_level'] ?? item['triage_level'] ?? 'medium').toString();

  String get _status =>
      (item['status'] ?? 'waiting').toString().toLowerCase();

  String? get _claimedBy => item['claimed_by'] as String?;

  bool get _isMine => _claimedBy == currentUserId;

  bool get _isUnclaimed => _claimedBy == null || _claimedBy!.isEmpty;

  Map<String, dynamic>? get _vitals {
    final data = item['triageUpdate'];
    if (data == null) return null;
    if (data is Map<String, dynamic>) return data;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      radius: AppRadius.md,
      glow: _urgency == 'emergency' ? AppColors.danger : null,
      glowOpacity: 0.2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          if (_complaint.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _complaint,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.inkMuted,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 8),
          _buildMetaRow(),
          if (_vitals != null) ...[
            const SizedBox(height: 8),
            _buildVitals(),
          ],
          const SizedBox(height: 10),
          _buildClaimButton(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Expanded(
          child: Text(
            _patientName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.ink,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        UrgencyBadge(level: _urgency),
      ],
    );
  }

  Widget _buildMetaRow() {
    return Row(
      children: [
        _StatusChip(status: _status),
        const SizedBox(width: 10),
        Icon(Icons.access_time, size: 13, color: AppColors.inkFaint),
        const SizedBox(width: 4),
        Text(
          _durationLabel(),
          style: const TextStyle(color: AppColors.inkFaint, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildVitals() {
    final v = _vitals!;
    final hr = v['heart_rate']?.toString();
    final bp = v['blood_pressure']?.toString();
    final temp = v['temperature']?.toString();

    final items = <_VitalEntry>[];
    if (hr != null) items.add(_VitalEntry('♥ $hr bpm'));
    if (bp != null) items.add(_VitalEntry('BP $bp'));
    if (temp != null) items.add(_VitalEntry('$temp°C'));
    if (items.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceGlass,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.borderGlass),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(width: 10),
              Container(width: 1, height: 12, color: AppColors.borderGlass),
              const SizedBox(width: 10),
            ],
            Text(
              items[i].label,
              style: const TextStyle(
                color: AppColors.inkMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildClaimButton() {
    final isAvailable = _isUnclaimed;
    final isMine = _isMine;

    if (_status == 'completed') {
      return const SizedBox.shrink();
    }

    if (isMine) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onUnclaim,
          icon: const Icon(Icons.undo, size: 16),
          label: const Text('Claimed by you — Release'),
        ),
      );
    }

    if (isAvailable) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onClaim,
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Claim'),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.lock_outline, size: 16),
        label: Text('Claimed by ${_claimedBy ?? ""}'),
      ),
    );
  }

  String _durationLabel() {
    final createdAt = DateTime.tryParse((item['created_at'] ?? '').toString());
    if (createdAt == null) return '—';
    final diff = DateTime.now().difference(createdAt);
    if (diff.inHours >= 1) return '${diff.inHours}h ${diff.inMinutes % 60}m';
    return '${diff.inMinutes}m';
  }
}

class _VitalEntry {
  final String label;
  const _VitalEntry(this.label);
}

/// Small status chip for queue state.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'waiting' => (AppColors.amber, 'Waiting'),
      'in_progress' => (AppColors.cyan, 'In Progress'),
      'completed' => (AppColors.success, 'Completed'),
      _ => (AppColors.blueGrey, status),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
