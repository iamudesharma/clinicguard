import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora_background.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_text.dart';

const _statusColors = {
  'confirmed': AppColors.success,
  'cancelled': AppColors.danger,
  'completed': AppColors.cyan,
};

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatSlot(String slot) {
  final dt = DateTime.tryParse(slot)?.toLocal();
  if (dt == null) return slot;
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '${_months[dt.month - 1]} ${dt.day} · $hh:$mm';
}

/// Lists all patient bookings with status badges and cancel action.
class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  final ApiClient _api = ApiClient();
  late Future<List<dynamic>> _bookingsFuture;

  @override
  void initState() {
    super.initState();
    _bookingsFuture = _api.fetchBookings('');
  }

  void _refresh() {
    setState(() {
      _bookingsFuture = _api.fetchBookings('');
    });
  }

  Future<void> _cancelBooking(String bookingId) async {
    try {
      await _api.deleteBooking(bookingId);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cancel failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppGradients.aurora,
                      ),
                      child: const Icon(
                        Icons.event_available,
                        color: AppColors.onGradient,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const GradientText(
                      'Appointments',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.surfaceGlass,
                        foregroundColor: AppColors.ink,
                        side: const BorderSide(color: AppColors.borderGlass),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBookingsList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBookingsList() {
    return FutureBuilder<List<dynamic>>(
      future: _bookingsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'Could not load appointments: ${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.inkMuted),
                  ),
                ),
                TextButton(
                  onPressed: _refresh,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }
        final bookings = snapshot.data ?? [];
        if (bookings.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'No appointments yet',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.inkMuted),
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          color: AppColors.cyan,
          backgroundColor: AppColors.surface,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: bookings.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final booking = bookings[i] as Map<String, dynamic>;
              return _BookingTile(
                booking: booking,
                onCancel: () => _cancelBooking('${booking['id']}'),
              );
            },
          ),
        );
      },
    );
  }
}

class _BookingTile extends StatelessWidget {
  final Map<String, dynamic> booking;
  final VoidCallback onCancel;

  const _BookingTile({required this.booking, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final slot = (booking['slot'] ?? '').toString();
    final reason = (booking['reason'] ?? '').toString();
    final status = (booking['status'] ?? '').toString();
    final color = _statusColors[status] ?? AppColors.inkMuted;

    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(14),
      radius: 20,
      glow: AppColors.teal,
      glowOpacity: 0.12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _formatSlot(slot),
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              style: const TextStyle(color: AppColors.inkMuted, fontSize: 13),
            ),
          ],
          if (status == 'confirmed') ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Cancel'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: const BorderSide(color: AppColors.danger),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
