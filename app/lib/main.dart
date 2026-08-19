import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import 'config.dart';
import 'services/platform_stt.dart';
import 'screens/auth_screen.dart';
import 'screens/bookings_screen.dart';
import 'screens/emergency_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/queue_screen.dart';
import 'state/auth_state.dart';
import 'state/call_state.dart';
import 'theme/app_theme.dart';
import 'widgets/aurora_background.dart';
import 'widgets/glow_nav_bar.dart';

/// Global platform STT instance — preloaded at app start so the first
/// call doesn't wait for initialization.
final PlatformSttService platformStt = PlatformSttService();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (AppConfig.supabaseUrl.isNotEmpty) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
  }

  // Preload platform STT in background (Apple/Web speech recognition).
  // This avoids a delay on the first call.
  platformStt.initialize().then((available) {
    if (available) {
      debugPrint('[main] platform STT preloaded OK');
    }
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthState()),
        ChangeNotifierProvider(create: (_) => CallState()),
      ],
      child: const MainApp(),
    ),
  );
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClinicGuard Triage',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const AuthGate(),
    );
  }
}

/// Routes between the auth screen and the main shell based on session state.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    if (auth.isSignedIn || auth.isGuest) return const MainShell();
    return const AuthScreen();
  }
}

/// Main navigation shell: triage + history tabs.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  Map<String, dynamic>? _lastEmergency;

  @override
  Widget build(BuildContext context) {
    final callState = context.watch<CallState>();
    // Navigate to EmergencyScreen when emergency_alert fires.
    final emergency = callState.emergencyAlert;
    if (emergency != null && emergency != _lastEmergency) {
      _lastEmergency = emergency;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => EmergencyScreen(emergencyData: emergency),
            ),
          );
        }
      });
    }

    return Scaffold(
      body: AuroraBackground(
        child: IndexedStack(
          index: _index,
          children: const [
            HomeScreen(),
            HistoryScreen(),
            QueueScreen(),
            BookingsScreen(),
          ],
        ),
      ),
      bottomNavigationBar: GlowNavBar(
        index: _index,
        onChanged: (i) => setState(() => _index = i),
        destinations: const [
          GlowNavDestination(
            icon: Icons.medical_information_outlined,
            selectedIcon: Icons.medical_information,
            label: 'Triage',
          ),
          GlowNavDestination(
            icon: Icons.history_outlined,
            selectedIcon: Icons.history,
            label: 'History',
          ),
          GlowNavDestination(
            icon: Icons.dashboard_outlined,
            selectedIcon: Icons.dashboard,
            label: 'Queue',
          ),
          GlowNavDestination(
            icon: Icons.calendar_month_outlined,
            selectedIcon: Icons.calendar_month,
            label: 'Bookings',
          ),
        ],
      ),
    );
  }
}
