import 'package:flutter/material.dart';

/// Small rounded badge showing urgency level with color coding.
class UrgencyBadge extends StatelessWidget {
  const UrgencyBadge({
    super.key,
    required this.level,
  });

  /// One of "low", "medium", "high", "emergency".
  final String level;

  Color get _backgroundColor => switch (level) {
        'low' => Colors.green,
        'medium' => Colors.amber,
        'high' => Colors.orange,
        'emergency' => Colors.red,
        _ => Colors.grey,
      };

  String get _label => switch (level) {
        'low' => 'LOW',
        'medium' => 'MED',
        'high' => 'HIGH',
        'emergency' => 'EMERG',
        _ => level.toUpperCase(),
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
