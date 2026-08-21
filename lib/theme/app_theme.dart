import 'package:flutter/material.dart';

/// Dawn-on-the-island palette.
///
/// Three surface steps do all the separating — no rules, no outlines between
/// regions. `canvas` is the content sheet, `shell` is the recessed chrome it
/// floats on (window frame, rail, page headers and footers), `panel` is the
/// raised step for cards, wells and bubbles. The single accent is reserved
/// for things that are alive or actionable: the presence signals, the pet's
/// aura, and primary actions.
abstract final class SynthPetColors {
  /// Cool dawn-blue-grey paper. The content sheet everything is read on.
  static const canvas = Color(0xFFE9EDF1);

  /// One recessed step below the canvas: the window frame, the navigation
  /// rail, page headers and footers. Separation by tone, never by a line.
  static const shell = Color(0xFFDCE3E9);

  /// A second recessed step for pressed and hovered chrome.
  static const shellDeep = Color(0xFFD2D9E0);

  /// One raised step above the canvas: bubbles, cards, input wells.
  static const panel = Color(0xFFF6F8FA);

  /// Near-black blue-grey ink. All text, all structure.
  static const ink = Color(0xFF20252C);

  /// Secondary text: ink at 56% over the canvas.
  static const inkSoft = Color(0xFF787D83);

  /// Control outlines only — never used to separate regions.
  static const hairline = Color(0xFFD1D5D9);

  /// Sunrise amber. The one accent.
  static const ember = Color(0xFFD97706);

  /// Ember at 14% over the canvas: selected rails, pressed fills.
  static const emberTint = Color(0xFFE7DCD0);

  /// Accent text on light surfaces (ember at readable contrast).
  static const emberDeep = Color(0xFF9A5500);

  /// Quiet brick red, errors only.
  static const brick = Color(0xFFB3402A);

  /// Brick at 10% over the canvas: error banner fill.
  static const brickTint = Color(0xFFE4DCDD);
}

/// The app's vernacular voice: the pet is ASCII text, so the chrome speaks
/// in terminal. Used for eyebrows, names, the face glyph, and metadata.
abstract final class SynthPetFonts {
  static const display = 'IBM Plex Mono';
  static const body = 'Avenir Next';
}

/// Builds the single app theme. Every screen reads from this one source;
/// nothing in the app hardcodes a color.
ThemeData buildSynthPetTheme() {
  const scheme = ColorScheme.light(
    primary: SynthPetColors.ember,
    onPrimary: SynthPetColors.ink,
    primaryContainer: SynthPetColors.emberTint,
    onPrimaryContainer: SynthPetColors.emberDeep,
    secondary: SynthPetColors.inkSoft,
    onSecondary: SynthPetColors.panel,
    secondaryContainer: SynthPetColors.emberTint,
    onSecondaryContainer: SynthPetColors.emberDeep,
    tertiary: SynthPetColors.inkSoft,
    onTertiary: SynthPetColors.panel,
    tertiaryContainer: SynthPetColors.panel,
    onTertiaryContainer: SynthPetColors.ink,
    error: SynthPetColors.brick,
    onError: Colors.white,
    errorContainer: SynthPetColors.brickTint,
    onErrorContainer: SynthPetColors.brick,
    surface: SynthPetColors.canvas,
    onSurface: SynthPetColors.ink,
    surfaceDim: SynthPetColors.shellDeep,
    surfaceBright: SynthPetColors.panel,
    surfaceContainerLowest: SynthPetColors.panel,
    surfaceContainerLow: SynthPetColors.panel,
    surfaceContainer: SynthPetColors.shell,
    surfaceContainerHigh: SynthPetColors.shellDeep,
    surfaceContainerHighest: SynthPetColors.shellDeep,
    outline: SynthPetColors.hairline,
    outlineVariant: SynthPetColors.hairline,
    inverseSurface: SynthPetColors.ink,
    onInverseSurface: SynthPetColors.canvas,
    inversePrimary: SynthPetColors.emberTint,
    surfaceTint: Colors.transparent,
    shadow: SynthPetColors.ink,
    scrim: SynthPetColors.ink,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: SynthPetFonts.body,
    scaffoldBackgroundColor: SynthPetColors.canvas,
    shadowColor: const Color(0x1A20252C),
    iconTheme: const IconThemeData(color: SynthPetColors.inkSoft),
  );

  final textTheme = base.textTheme
      .apply(fontFamily: SynthPetFonts.body)
      .copyWith(
        displaySmall: base.textTheme.displaySmall?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.5,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.4),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          height: 1.4,
          fontSize: 13.5,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          height: 1.35,
          color: SynthPetColors.inkSoft,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: 11.5,
          letterSpacing: 0.2,
          color: SynthPetColors.inkSoft,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(
          fontFamily: SynthPetFonts.display,
          fontSize: 10.5,
          letterSpacing: 0.4,
          fontWeight: FontWeight.w400,
          color: SynthPetColors.inkSoft,
        ),
      );

  return base.copyWith(
    textTheme: textTheme,
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      labelType: NavigationRailLabelType.none,
      indicatorColor: SynthPetColors.emberTint,
      selectedIconTheme: IconThemeData(color: SynthPetColors.ink),
      unselectedIconTheme: IconThemeData(color: SynthPetColors.inkSoft),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      indicatorColor: SynthPetColors.emberTint,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? SynthPetColors.ink
              : SynthPetColors.inkSoft,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: SynthPetColors.panel,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: SynthPetColors.ember,
        foregroundColor: SynthPetColors.ink,
        disabledBackgroundColor: SynthPetColors.hairline,
        disabledForegroundColor: SynthPetColors.inkSoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(
          fontFamily: SynthPetFonts.body,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SynthPetColors.ink,
        side: const BorderSide(color: SynthPetColors.hairline, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(
          fontFamily: SynthPetFonts.body,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: SynthPetColors.inkSoft,
        textStyle: const TextStyle(
          fontFamily: SynthPetFonts.body,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: SynthPetColors.panel,
      hintStyle: const TextStyle(
        color: SynthPetColors.inkSoft,
        fontSize: 13.5,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: SynthPetColors.ember),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: SynthPetColors.ember,
      linearTrackColor: SynthPetColors.panel,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: SynthPetColors.ember,
      selectionColor: SynthPetColors.emberTint,
      selectionHandleColor: SynthPetColors.emberDeep,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: base.textTheme.bodySmall?.copyWith(
        color: SynthPetColors.inkSoft,
      ),
    ),
  );
}
