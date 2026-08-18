import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../services/api_client.dart';
import '../state/auth_state.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora_background.dart';
import '../widgets/glass_card.dart';
import '../widgets/gradient_text.dart';
import '../widgets/queue_card.dart';

/// Clinician queue dashboard with filtering and realtime updates.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final ApiClient _api = ApiClient();
  String _selectedStatus = '';
  late Future<List<dynamic>> _queueFuture;
  RealtimeChannel? _channel;

  static const _filters = [
    ('', 'All'),
    ('waiting', 'Waiting'),
    ('in_progress', 'In Progress'),
    ('completed', 'Completed'),
  ];

  @override
  void initState() {
    super.initState();
    _queueFuture = _api.fetchQueue(status: _selectedStatus);
    _subscribeRealtime();
  }

  void _subscribeRealtime() {
    final client = Supabase.instance.client;
    _channel = client.realtime.channel('queue-changes');
    _channel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sessions',
          callback: (_) => _refresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'triage_results',
          callback: (_) => _refresh(),
        )
        .subscribe();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _queueFuture = _api.fetchQueue(status: _selectedStatus);
    });
  }

  void _onFilter(String status) {
    setState(() {
      _selectedStatus = status;
      _queueFuture = _api.fetchQueue(status: status);
    });
  }

  Future<void> _claim(String roomId) async {
    try {
      await _api.claimSession(roomId);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Claim failed: $e')),
      );
    }
  }

  Future<void> _unclaim(String roomId) async {
    try {
      await _api.unclaimSession(roomId);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unclaim failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final isClinician = auth.isSignedIn && auth.user != null;

    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              if (!isClinician)
                Expanded(child: _buildLoginRequired())
              else ...[
                _buildFilterChips(),
                Expanded(child: _buildQueueList()),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
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
              Icons.groups,
              color: AppColors.onGradient,
              size: 16,
            ),
          ),
          const SizedBox(width: 10),
          const GradientText(
            'Clinician Queue',
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
    );
  }

  Widget _buildFilterChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _filters.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final (status, label) = _filters[i];
            final selected = _selectedStatus == status;
            return ChoiceChip(
              label: Text(label),
              selected: selected,
              onSelected: (_) => _onFilter(status),
              selectedColor: AppColors.cyan,
              labelStyle: TextStyle(
                color: selected ? AppColors.onGradient : AppColors.inkMuted,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildQueueList() {
    return FutureBuilder<List<dynamic>>(
      future: _queueFuture,
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
                    'Could not load queue: ${snapshot.error}',
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
        final sessions = snapshot.data ?? [];
        if (sessions.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'No sessions in queue.',
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
          child: ListView.builder(
            padding: const EdgeInsets.only(top: 4, bottom: 24),
            itemCount: sessions.length,
            itemBuilder: (context, i) {
              final item = sessions[i] as Map<String, dynamic>;
              final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
              return QueueCard(
                item: item,
                currentUserId: userId,
                onClaim: () => _claim((item['room_id'] ?? '').toString()),
                onUnclaim: () => _unclaim((item['room_id'] ?? '').toString()),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildLoginRequired() {
    return Center(
      child: GlassCard(
        padding: const EdgeInsets.all(32),
        radius: AppRadius.lg,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 40, color: AppColors.inkFaint),
            SizedBox(height: 16),
            Text(
              'Clinician login required',
              style: TextStyle(
                color: AppColors.ink,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Sign in with a clinician account to access the queue.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.inkMuted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
