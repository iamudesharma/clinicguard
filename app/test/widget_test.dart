import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:clinic_guard/main.dart';
import 'package:clinic_guard/screens/home_screen.dart';
import 'package:clinic_guard/state/auth_state.dart';
import 'package:clinic_guard/state/call_state.dart';
import 'package:clinic_guard/widgets/animated_transcript_bubble.dart';
import 'package:clinic_guard/widgets/voice_orb.dart';
import 'package:clinic_guard/widgets/voice_wave_visualizer.dart';

Widget _app(Widget home) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => AuthState()),
      ChangeNotifierProvider(create: (_) => CallState()),
    ],
    child: MaterialApp(home: home),
  );
}

void main() {
  testWidgets('home screen shows the triage start button and orb', (tester) async {
    await tester.pumpWidget(_app(const HomeScreen()));

    expect(find.text('ClinicGuard Triage'), findsOneWidget);
    expect(find.textContaining('Start Triage Call'), findsOneWidget);
    expect(find.byType(VoiceOrb), findsOneWidget);
  });

  testWidgets('auth gate shows guest entry when signed out', (tester) async {
    await tester.pumpWidget(_app(const AuthGate()));

    expect(find.textContaining('Continue as guest'), findsOneWidget);
  });

  testWidgets('VoiceWaveVisualizer renders without crashing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VoiceWaveVisualizer(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(VoiceWaveVisualizer), findsOneWidget);
  });

  testWidgets('TranscriptBubble renders user and assistant bubbles', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TranscriptBubble(text: 'I have a sore throat', isUser: true),
              TranscriptBubble(text: 'How long have you had it?', isUser: false),
            ],
          ),
        ),
      ),
    );

    expect(find.text('I have a sore throat'), findsOneWidget);
    expect(find.text('How long have you had it?'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('ClinicGuard AI'), findsOneWidget);
  });

  testWidgets('VoiceOrb renders in all modes', (tester) async {
    for (final mode in OrbMode.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceOrb(mode: mode, size: 100),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(VoiceOrb), findsOneWidget);
    }
  });
}
