import 'package:flutter/material.dart';

/// The app's two faces, the pair the rest of the fleet ships: [sans] is the
/// voice of the interface, [mono] the terminal one. Mono is not decoration —
/// it is what the pet is made of. The ASCII face, reasoning traces, code and
/// metadata are set in it so their columns line up; everything a reader reads
/// as prose is Nunito.
abstract final class PersynthFonts {
  static const sans = 'Nunito';
  static const mono = 'IBM Plex Mono';
}

/// Dawn-on-the-island palette, in a light and a dusk variant.
///
/// Three surface steps do all the separating — no rules, no outlines between
/// regions. `canvas` is the content sheet, `shell` is the recessed chrome it
/// floats on (window frame, rail, page headers and footers), `panel` is the
/// raised step for cards, wells and bubbles. The single accent is reserved
/// for things that are alive or actionable: the presence signals, the pet's
/// aura, and primary actions.
class PersynthPalette {
  const PersynthPalette({
    required this.canvas,
    required this.shell,
    required this.shellDeep,
    required this.panel,
    required this.ink,
    required this.inkSoft,
    required this.hairline,
    required this.ember,
    required this.emberTint,
    required this.emberDeep,
    required this.brick,
    required this.brickTint,
  });

  /// Cool dawn-blue-grey paper (light) / near-black slate (dark). The
  /// content sheet everything is read on.
  final Color canvas;

  /// One recessed step below the canvas: the window frame, the navigation
  /// rail, page headers and footers. Separation by tone, never by a line.
  final Color shell;

  /// A second recessed step for pressed and hovered chrome.
  final Color shellDeep;

  /// One raised step above the canvas: bubbles, cards, input wells.
  final Color panel;

  /// Primary text and structure. Near-black blue-grey on light, near-white
  /// on dark.
  final Color ink;

  /// Secondary text: ink at reduced strength.
  final Color inkSoft;

  /// Control outlines only — never used to separate regions.
  final Color hairline;

  /// Sunrise amber. The one accent.
  final Color ember;

  /// Accent at low strength over the canvas: selected rails, pressed fills.
  final Color emberTint;

  /// Accent text at readable contrast on the current surfaces.
  final Color emberDeep;

  /// Quiet brick red, errors only.
  final Color brick;

  /// Brick at low strength over the canvas: error banner fill.
  final Color brickTint;

  /// The default daylight look.
  static const light = PersynthPalette(
    canvas: Color(0xFFE9EDF1),
    shell: Color(0xFFDCE3E9),
    shellDeep: Color(0xFFD2D9E0),
    panel: Color(0xFFF6F8FA),
    ink: Color(0xFF20252C),
    inkSoft: Color(0xFF787D83),
    hairline: Color(0xFFD1D5D9),
    ember: Color(0xFFD97706),
    emberTint: Color(0xFFE7DCD0),
    emberDeep: Color(0xFF9A5500),
    brick: Color(0xFFB3402A),
    brickTint: Color(0xFFE4DCDD),
  );

  /// Dusk look — same structure, surfaces inverted, accent lifted for
  /// contrast on dark surfaces.
  static const dark = PersynthPalette(
    canvas: Color(0xFF14171B),
    shell: Color(0xFF1B1F24),
    shellDeep: Color(0xFF242A31),
    panel: Color(0xFF20252B),
    ink: Color(0xFFE8EBEF),
    inkSoft: Color(0xFF99A0A8),
    hairline: Color(0xFF2F363E),
    ember: Color(0xFFF59E0B),
    emberTint: Color(0xFF3B2F1D),
    emberDeep: Color(0xFFFBBF24),
    brick: Color(0xFFE06A50),
    brickTint: Color(0xFF3A2622),
  );
}

/// Builds the single app theme for [brightness]. Every screen reads from
/// this one source; nothing in the app hardcodes a color.
ThemeData buildPersynthTheme(Brightness brightness) {
  final p = brightness == Brightness.dark
      ? PersynthPalette.dark
      : PersynthPalette.light;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.ember,
    onPrimary: brightness == Brightness.dark ? Colors.black : p.ink,
    primaryContainer: p.emberTint,
    onPrimaryContainer: p.emberDeep,
    secondary: p.inkSoft,
    onSecondary: p.panel,
    secondaryContainer: p.emberTint,
    onSecondaryContainer: p.emberDeep,
    tertiary: p.inkSoft,
    onTertiary: p.panel,
    tertiaryContainer: p.panel,
    onTertiaryContainer: p.ink,
    error: p.brick,
    onError: brightness == Brightness.dark ? Colors.black : Colors.white,
    errorContainer: p.brickTint,
    onErrorContainer: p.brick,
    surface: p.canvas,
    onSurface: p.ink,
    surfaceDim: p.shellDeep,
    surfaceBright: p.panel,
    surfaceContainerLowest: p.panel,
    surfaceContainerLow: p.panel,
    surfaceContainer: p.shell,
    surfaceContainerHigh: p.shellDeep,
    surfaceContainerHighest: p.shellDeep,
    outline: p.hairline,
    outlineVariant: p.hairline,
    inverseSurface: p.ink,
    onInverseSurface: p.canvas,
    inversePrimary: p.emberTint,
    surfaceTint: Colors.transparent,
    shadow: Colors.transparent,
    scrim: Colors.black,
    onSurfaceVariant: p.inkSoft,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: PersynthFonts.sans,
    scaffoldBackgroundColor: p.canvas,
    shadowColor: Colors.transparent,
    iconTheme: IconThemeData(color: p.inkSoft),
  );

  final textTheme = base.textTheme
      .apply(fontFamily: PersynthFonts.sans)
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
          color: p.inkSoft,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: 11.5,
          letterSpacing: 0.2,
          color: p.inkSoft,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(
          fontFamily: PersynthFonts.mono,
          fontSize: 10.5,
          letterSpacing: 0.4,
          fontWeight: FontWeight.w400,
          color: p.inkSoft,
        ),
      );

  return base.copyWith(
    textTheme: textTheme,
    appBarTheme: AppBarThemeData(
      backgroundColor: p.shell,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: IconThemeData(color: p.inkSoft),
      actionsIconTheme: IconThemeData(color: p.inkSoft),
      titleTextStyle: textTheme.titleSmall?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.emberDeep,
      unselectedLabelColor: p.inkSoft,
      indicatorColor: p.ember,
      dividerColor: Colors.transparent,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      labelType: NavigationRailLabelType.none,
      indicatorColor: p.emberTint,
      selectedIconTheme: IconThemeData(color: p.ink),
      unselectedIconTheme: IconThemeData(color: p.inkSoft),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      indicatorColor: p.emberTint,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? p.ink : p.inkSoft,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: p.panel,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.ember,
        foregroundColor: brightness == Brightness.dark ? Colors.black : p.ink,
        disabledBackgroundColor: p.hairline,
        disabledForegroundColor: p.inkSoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(
          fontFamily: PersynthFonts.sans,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: BorderSide(color: p.hairline, width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(
          fontFamily: PersynthFonts.sans,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.inkSoft,
        textStyle: const TextStyle(
          fontFamily: PersynthFonts.sans,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // The canvas tone recesses a field against the panel cards, sheets and
      // bars it sits on; a panel fill matched them and vanished.
      fillColor: p.canvas,
      hintStyle: TextStyle(color: p.inkSoft, fontSize: 13.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      // A field is outlined, not just filled: the fill alone cannot separate
      // it from a card of the same tone. This entry fixes the outline's shape
      // (a filled field with no theme border falls back to an underline).
      // Deliberately only `border`, never `enabledBorder` — that outranks a
      // field's own `border: InputBorder.none`, and the composer and the
      // island opt out exactly that way.
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: p.inkSoft),
      ),
      // Focus is the caret's job here; left unset, the M3 defaults would ring
      // the field in the accent colour. Pin it to the resting stroke instead.
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: p.inkSoft),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.ember,
      linearTrackColor: p.panel,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.ember,
      selectionColor: p.emberTint,
      selectionHandleColor: p.emberDeep,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: base.textTheme.bodySmall?.copyWith(color: p.inkSoft),
    ),
  );
}
