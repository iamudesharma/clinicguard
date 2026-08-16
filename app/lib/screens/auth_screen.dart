import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_state.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora_background.dart';
import '../widgets/glass_card.dart';
import '../widgets/glow_button.dart';
import '../widgets/gradient_text.dart';

/// Sign in / sign up / guest entry screen shown before the main shell.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit(AuthState auth) async {
    if (!_formKey.currentState!.validate()) return;
    if (_isSignUp) {
      await auth.signUp(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } else {
      await auth.signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();

    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _GlowLogo(),
                    const SizedBox(height: 20),
                    const GradientText(
                      'ClinicGuard Triage',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Voice triage for your clinic',
                      style: TextStyle(color: AppColors.inkMuted, fontSize: 14),
                    ),
                    const SizedBox(height: 24),
                    GlassCard(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      glow: AppColors.violet,
                      glowOpacity: 0.15,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (auth.isSupabaseConfigured) ...[
                            SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(
                                  value: false,
                                  label: Text('Sign In'),
                                ),
                                ButtonSegment(
                                  value: true,
                                  label: Text('Sign Up'),
                                ),
                              ],
                              selected: {_isSignUp},
                              showSelectedIcon: false,
                              onSelectionChanged: (selection) =>
                                  setState(() => _isSignUp = selection.first),
                            ),
                            const SizedBox(height: 20),
                            Form(
                              key: _formKey,
                              child: Column(
                                children: [
                                  if (_isSignUp) ...[
                                    TextFormField(
                                      controller: _nameController,
                                      decoration: const InputDecoration(
                                        labelText: 'Full name',
                                        prefixIcon: Icon(Icons.person_outline),
                                      ),
                                      validator: (v) =>
                                          (v == null || v.trim().isEmpty)
                                          ? 'Enter your name'
                                          : null,
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  TextFormField(
                                    controller: _emailController,
                                    keyboardType: TextInputType.emailAddress,
                                    decoration: const InputDecoration(
                                      labelText: 'Email',
                                      prefixIcon: Icon(Icons.email_outlined),
                                    ),
                                    validator: (v) =>
                                        (v == null || !v.contains('@'))
                                        ? 'Enter a valid email'
                                        : null,
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _passwordController,
                                    obscureText: _obscurePassword,
                                    decoration: InputDecoration(
                                      labelText: 'Password',
                                      prefixIcon: const Icon(
                                        Icons.lock_outline,
                                      ),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_off
                                              : Icons.visibility,
                                        ),
                                        onPressed: () => setState(
                                          () => _obscurePassword =
                                              !_obscurePassword,
                                        ),
                                      ),
                                    ),
                                    validator: (v) =>
                                        (v == null || v.length < 6)
                                        ? 'Password must be at least 6 characters'
                                        : null,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: GlowButton(
                                label: _isSignUp ? 'Create account' : 'Sign In',
                                loading: auth.loading,
                                onPressed: auth.loading
                                    ? null
                                    : () => _submit(auth),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                radius: 14,
                              ),
                            ),
                            if (auth.error.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                auth.error,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: AppColors.danger),
                              ),
                            ],
                            const SizedBox(height: 20),
                            const Divider(),
                          ] else ...[
                            const Text(
                              'No account service configured — using guest mode.',
                            ),
                            const SizedBox(height: 20),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: auth.loading
                            ? null
                            : () => context.read<AuthState>().enterGuest(),
                        icon: const Icon(Icons.person_outline),
                        label: const Text('Continue as guest'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pulsing glow ring behind a gradient logo circle (Gemini-Live style).
class _GlowLogo extends StatefulWidget {
  const _GlowLogo();

  @override
  State<_GlowLogo> createState() => _GlowLogoState();
}

class _GlowLogoState extends State<_GlowLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      if (reduce) {
        _controller.stop();
        _controller.value = 0.5;
      } else {
        _controller.repeat(reverse: true);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final v = _controller.value;
        return SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: 1 + 0.06 * v,
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.borderGlassStrong),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.cyan.withValues(alpha: 0.35 + 0.3 * v),
                        blurRadius: 18 + 10 * v,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppGradients.aurora,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.cyan.withValues(alpha: 0.5),
                      blurRadius: 22,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.medical_information,
                  color: AppColors.onGradient,
                  size: 30,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
