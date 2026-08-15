import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:clinic_guard/screens/home_screen.dart';
import 'package:clinic_guard/state/call_state.dart';

void main() {
  testWidgets('home screen shows the triage start button', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => CallState(),
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.text('ClinicGuard Triage'), findsOneWidget);
    expect(find.text('Start triage call'), findsOneWidget);
  });
}
