import 'dart:ui';

import 'package:flutter/material.dart';

@immutable
class LightwhisperThemeV2 extends ThemeExtension<LightwhisperThemeV2> {
  const LightwhisperThemeV2({
    required this.backgroundGradientTop,
    required this.backgroundGradientBottom,
    required this.surfaceGlassSoft,
    required this.surfaceGlassMedium,
    required this.glassBorder,
    required this.primaryAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.recordingAccent,
    required this.warningAccent,
    required this.radiusContainer,
    required this.radiusCard,
    required this.radiusButton,
    required this.space4,
    required this.space8,
    required this.space12,
    required this.space16,
    required this.space24,
    required this.space32,
    required this.shadowLow,
    required this.shadowMedium,
    required this.shadowHigh,
  });

  final Color backgroundGradientTop;
  final Color backgroundGradientBottom;
  final Color surfaceGlassSoft;
  final Color surfaceGlassMedium;
  final Color glassBorder;
  final Color primaryAccent;
  final Color textPrimary;
  final Color textSecondary;
  final Color recordingAccent;
  final Color warningAccent;

  final double radiusContainer;
  final double radiusCard;
  final double radiusButton;

  final double space4;
  final double space8;
  final double space12;
  final double space16;
  final double space24;
  final double space32;

  final List<BoxShadow> shadowLow;
  final List<BoxShadow> shadowMedium;
  final List<BoxShadow> shadowHigh;

  static const LightwhisperThemeV2 light = LightwhisperThemeV2(
    backgroundGradientTop: Color(0xFFF8FAFF),
    backgroundGradientBottom: Color(0xFFEAF0FB),
    surfaceGlassSoft: Color(0xBFFFFFFF),
    surfaceGlassMedium: Color(0xD9FFFFFF),
    glassBorder: Color(0xCCFFFFFF),
    primaryAccent: Color(0xFF3C7CFF),
    textPrimary: Color(0xFF1A2740),
    textSecondary: Color(0xFF51607B),
    recordingAccent: Color(0xFFFFD84D),
    warningAccent: Color(0xFFFF9F43),
    radiusContainer: 16,
    radiusCard: 20,
    radiusButton: 14,
    space4: 4,
    space8: 8,
    space12: 12,
    space16: 16,
    space24: 24,
    space32: 32,
    shadowLow: [
      BoxShadow(
        color: Color(0x0F1A2740),
        blurRadius: 8,
        offset: Offset(0, 2),
      ),
    ],
    shadowMedium: [
      BoxShadow(
        color: Color(0x14203A66),
        blurRadius: 16,
        offset: Offset(0, 6),
      ),
    ],
    shadowHigh: [
      BoxShadow(
        color: Color(0x1A203A66),
        blurRadius: 24,
        offset: Offset(0, 10),
      ),
    ],
  );

  @override
  LightwhisperThemeV2 copyWith({
    Color? backgroundGradientTop,
    Color? backgroundGradientBottom,
    Color? surfaceGlassSoft,
    Color? surfaceGlassMedium,
    Color? glassBorder,
    Color? primaryAccent,
    Color? textPrimary,
    Color? textSecondary,
    Color? recordingAccent,
    Color? warningAccent,
    double? radiusContainer,
    double? radiusCard,
    double? radiusButton,
    double? space4,
    double? space8,
    double? space12,
    double? space16,
    double? space24,
    double? space32,
    List<BoxShadow>? shadowLow,
    List<BoxShadow>? shadowMedium,
    List<BoxShadow>? shadowHigh,
  }) {
    return LightwhisperThemeV2(
      backgroundGradientTop: backgroundGradientTop ?? this.backgroundGradientTop,
      backgroundGradientBottom:
          backgroundGradientBottom ?? this.backgroundGradientBottom,
      surfaceGlassSoft: surfaceGlassSoft ?? this.surfaceGlassSoft,
      surfaceGlassMedium: surfaceGlassMedium ?? this.surfaceGlassMedium,
      glassBorder: glassBorder ?? this.glassBorder,
      primaryAccent: primaryAccent ?? this.primaryAccent,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      recordingAccent: recordingAccent ?? this.recordingAccent,
      warningAccent: warningAccent ?? this.warningAccent,
      radiusContainer: radiusContainer ?? this.radiusContainer,
      radiusCard: radiusCard ?? this.radiusCard,
      radiusButton: radiusButton ?? this.radiusButton,
      space4: space4 ?? this.space4,
      space8: space8 ?? this.space8,
      space12: space12 ?? this.space12,
      space16: space16 ?? this.space16,
      space24: space24 ?? this.space24,
      space32: space32 ?? this.space32,
      shadowLow: shadowLow ?? this.shadowLow,
      shadowMedium: shadowMedium ?? this.shadowMedium,
      shadowHigh: shadowHigh ?? this.shadowHigh,
    );
  }

  @override
  LightwhisperThemeV2 lerp(ThemeExtension<LightwhisperThemeV2>? other, double t) {
    if (other is! LightwhisperThemeV2) return this;
    return LightwhisperThemeV2(
      backgroundGradientTop:
          Color.lerp(backgroundGradientTop, other.backgroundGradientTop, t)!,
      backgroundGradientBottom:
          Color.lerp(backgroundGradientBottom, other.backgroundGradientBottom, t)!,
      surfaceGlassSoft: Color.lerp(surfaceGlassSoft, other.surfaceGlassSoft, t)!,
      surfaceGlassMedium:
          Color.lerp(surfaceGlassMedium, other.surfaceGlassMedium, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      primaryAccent: Color.lerp(primaryAccent, other.primaryAccent, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      recordingAccent: Color.lerp(recordingAccent, other.recordingAccent, t)!,
      warningAccent: Color.lerp(warningAccent, other.warningAccent, t)!,
      radiusContainer: lerpDouble(radiusContainer, other.radiusContainer, t)!,
      radiusCard: lerpDouble(radiusCard, other.radiusCard, t)!,
      radiusButton: lerpDouble(radiusButton, other.radiusButton, t)!,
      space4: lerpDouble(space4, other.space4, t)!,
      space8: lerpDouble(space8, other.space8, t)!,
      space12: lerpDouble(space12, other.space12, t)!,
      space16: lerpDouble(space16, other.space16, t)!,
      space24: lerpDouble(space24, other.space24, t)!,
      space32: lerpDouble(space32, other.space32, t)!,
      shadowLow: t < 0.5 ? shadowLow : other.shadowLow,
      shadowMedium: t < 0.5 ? shadowMedium : other.shadowMedium,
      shadowHigh: t < 0.5 ? shadowHigh : other.shadowHigh,
    );
  }
}

ThemeData buildLightwhisperTheme() {
  const tokens = LightwhisperThemeV2.light;
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: base.colorScheme.copyWith(
      primary: tokens.primaryAccent,
      surface: const Color(0xFFF4F7FD),
      onSurface: tokens.textPrimary,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: tokens.textPrimary,
      displayColor: tokens.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: tokens.textPrimary,
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1A2740),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE21314F),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radiusButton),
      ),
    ),
    extensions: const <ThemeExtension<dynamic>>[
      LightwhisperThemeV2.light,
    ],
  );
}
