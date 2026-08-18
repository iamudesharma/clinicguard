import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;

import '../config.dart';
import '../services/api_client.dart';

/// Auth state backed by Supabase Auth (email/password), with a guest fallback
/// so the demo works without an account.
class AuthState extends ChangeNotifier {
  final ApiClient _api = ApiClient();
  StreamSubscription<dynamic>? _authSub;

  User? user;
  bool isSignedIn = false;
  bool isGuest = false;
  bool loading = false;
  String error = '';

  bool get isSupabaseConfigured => AppConfig.supabaseUrl.isNotEmpty;

  /// Returns true if the current user has the 'clinician' role in app_metadata.
  bool get isClinician {
    final u = user;
    if (u == null) return false;
    final role = u.appMetadata['role'];
    return role == 'clinician';
  }

  AuthState() {
    // tests construct AuthState without Supabase
    try {
      _authSub = Supabase.instance.client.auth.onAuthStateChange.listen(
        (event) {
          if (event.event == AuthChangeEvent.signedOut) {
            user = null;
            isSignedIn = false;
          } else {
            user = event.session?.user;
            isSignedIn = event.session != null;
          }
          notifyListeners();
        },
      );
    } catch (_) {}
  }

  /// Creates an account (email confirmation may be required first), then
  /// best-effort registers the patient with the backend.
  Future<void> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    loading = true;
    error = '';
    notifyListeners();
    try {
      await Supabase.instance.client.auth.signUp(
        email: email,
        password: password,
        data: {'display_name': name},
      );
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) {
        error = 'Check your email to confirm your account, then sign in.';
      } else {
        try {
          await _api.createPatient(name: name, ownerId: session.user.id);
        } catch (_) {
          // demo best-effort
        }
      }
    } catch (e) {
      error = _friendlyError(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Signs in with email/password, mapping common Supabase errors to
  /// friendly messages.
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    loading = true;
    error = '';
    notifyListeners();
    try {
      await Supabase.instance.client.auth
          .signInWithPassword(email: email, password: password);
    } catch (e) {
      error = _friendlyError(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Signs out of the Supabase session; local state is reset even if the
  /// remote call fails.
  Future<void> signOut() async {
    loading = true;
    notifyListeners();
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      // ignore — Supabase may not be reachable/configured
    } finally {
      user = null;
      isSignedIn = false;
      loading = false;
      notifyListeners();
    }
  }

  /// Enters the demo guest mode (no account).
  void enterGuest() {
    isGuest = true;
    error = '';
    notifyListeners();
  }

  /// Leaves guest mode.
  void exitGuest() {
    isGuest = false;
    notifyListeners();
  }

  String _friendlyError(Object e) {
    final message = e is AuthException ? e.message : e.toString();
    final lower = message.toLowerCase();
    if (lower.contains('invalid login credentials')) {
      return 'Email or password is incorrect';
    }
    if (lower.contains('user already registered') ||
        lower.contains('user already exists')) {
      return 'An account with this email already exists';
    }
    if (lower.contains('email not confirmed')) {
      return 'Please confirm your email first.';
    }
    return message;
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
