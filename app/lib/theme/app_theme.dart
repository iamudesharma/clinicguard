import 'package:flutter/material.dart';

/// Design tokens for the dark aurora redesign (Gemini-Live inspired):
/// deep navy canvas, aurora gradient trio, glassmorphism surfaces, glow.
abstract final class AppColors {
  static const canvas = Color(0xFF070B14);
  static const surface = Color(0xFF0D1526);
  static const surfaceCard = Color(0xFF101B30);

  /// White 7% — frosted surface fill.
  static const surfaceGlass = Color(0x12FFFFFF);

  /// White 12% — stronger frosted surface fill.
  static const surfaceGlassStrong = Color(0x1FFFFFFF);

  /// White 15% — hairline glass border.
  static const borderGlass = Color(0x26FFFFFF);

  /// White 24% — emphasis glass border.
  static const borderGlassStrong = Color(0x3DFFFFFF);

  static const ink = Color(0xFFF2F6FF);
  static const inkMuted = Color(0xFF94A3B8);
  static const inkFaint = Color(0xFF64748B);

  // Luminous vibrant accents (Gemini / ChatGPT / Grok inspired)
  static const teal = Color(0xFF14E0B4);
  static const electricTeal = Color(0xFF00F5D4);
  static const cyan = Color(0xFF38BDF8);
  static const neonCyan = Color(0xFF00F0FF);
  static const violet = Color(0xFF8B5CF6);
  static const plasmaViolet = Color(0xFF7928CA);
  static const fuchsia = Color(0xFFD946EF);
  static const auroraFuchsia = Color(0xFFFF007F);
  static const amber = Color(0xFFFBBF24);
  static const amberGlow = Color(0xFFFFB703);
  static const orange = Color(0xFFFB923C);
  static const danger = Color(0xFFF87171);
  static const coralRed = Color(0xFFFF3366);
  static const success = Color(0xFF34D399);
  static const blueGrey = Color(0xFF64748B);

  // Clinical Triage Urgency levels
  static const triageEmergency = Color(0xFFFF2A6D);
  static const triageUrgent = Color(0xFFFFB703);
  static const triageRoutine = Color(0xFF00F5D4);

  /// Ink color used on top of bright gradient fills.
  static const onGradient = Color(0xFF04121A);
}

abstract final class AppGradients {
  static const aurora = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.teal, AppColors.cyan, AppColors.violet],
  );

  /// Hot variant for the speaking state (violet -> fuchsia -> cyan).
  static const auroraHot = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.violet, AppColors.fuchsia, AppColors.cyan],
  );

  /// Gemini Live radiant swirl (cyan -> fuchsia -> electric teal).
  static const geminiRadiant = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.neonCyan, AppColors.auroraFuchsia, AppColors.electricTeal],
  );

  /// Grok Cosmic electric flare (plasma violet -> neon cyan -> amber glow).
  static const grokCosmic = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.plasmaViolet, AppColors.neonCyan, AppColors.amberGlow],
  );

  /// User transcript bubble (teal -> cyan).
  static const userBubble = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0FB5A8), AppColors.cyan],
  );

  /// Assistant glowing glass bubble background.
  static const assistantBubble = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0x2838BDF8), // cyan @ 16%
      Color(0x188B5CF6), // violet @ 10%
      Color(0x100D1526), // dark surface
    ],
  );

  /// Bottom nav selection pill — soft translucent aurora.
  static const navPill = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0x47E2E80F), // teal @ 28%
      Color(0x4738BDF8), // cyan @ 28%
      Color(0x478B5CF6), // violet @ 28%
    ],
  );

  /// The aurora trio for a given agent state ('idle'|'listening'|'thinking'|
  /// 'speaking'), shared by the orb, status pill and accent glows.
  static LinearGradient forAgentState(String state) => switch (state) {
        'speaking' => auroraHot,
        'thinking' => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.amber, AppColors.orange],
          ),
        'listening' => aurora,
        _ => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.blueGrey, AppColors.violet],
          ),
      };

  /// Accent color for a given agent state.
  static Color accentForAgentState(String state) => switch (state) {
        'speaking' => AppColors.fuchsia,
        'thinking' => AppColors.amber,
        'listening' => AppColors.teal,
        _ => AppColors.blueGrey,
      };
}

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class AppRadius {
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const pill = 999.0;
}

abstract final class AppTheme {
  static ThemeData dark() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        surface: AppColors.canvas,
        onSurface: AppColors.ink,
        surfaceContainerHighest: AppColors.surface,
        onSurfaceVariant: AppColors.inkMuted,
        primary: AppColors.cyan,
        onPrimary: AppColors.onGradient,
        secondary: AppColors.teal,
        onSecondary: AppColors.onGradient,
        error: AppColors.danger,
        onError: Color(0xFF2A0A0A),
        outline: AppColors.borderGlassStrong,
        outlineVariant: AppColors.borderGlass,
      ),
      scaffoldBackgroundColor: AppColors.canvas,
    );

    final text = base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    );

    return base.copyWith(
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: AppColors.ink,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceGlass,
        labelStyle: const TextStyle(color: AppColors.inkMuted),
        hintStyle: const TextStyle(color: AppColors.inkFaint),
        prefixIconColor: AppColors.inkMuted,
        suffixIconColor: AppColors.inkMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.borderGlass),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.borderGlass),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.cyan, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.cyan,
          foregroundColor: AppColors.onGradient,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          side: const BorderSide(color: AppColors.borderGlassStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.cyan),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppColors.surfaceGlass,
        side: const BorderSide(color: AppColors.borderGlass),
        labelStyle: const TextStyle(color: AppColors.ink, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.borderGlass,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.surface,
        contentTextStyle: const TextStyle(color: AppColors.ink),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        titleTextStyle: const TextStyle(
          color: AppColors.ink,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: const TextStyle(color: AppColors.inkMuted),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.cyan),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: AppColors.cyan.withValues(alpha: 0.18),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? AppColors.cyan
                : AppColors.inkMuted,
          ),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
