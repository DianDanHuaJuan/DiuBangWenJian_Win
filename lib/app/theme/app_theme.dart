import 'package:flutter/material.dart';

/// 全局主题。正文字体为捆绑的 **Noto Sans SC**（SIL OFL，开源可商用）。
///
/// pubspec 仅注册 Regular(400) / Bold(700)；中间字重会合成加粗，
/// 部分汉字字宽异常，故正文用 400、强调用 700。
ThemeData buildAppTheme() {
  const scaffoldColor = Color(0xFFF5F4F1);
  const surfaceColor = Colors.white;
  const primaryColor = Color(0xFF3D8A5A);
  const primarySoftColor = Color(0xFFE8F3EB);
  const textColor = Color(0xFF1A1918);
  const mutedTextColor = Color(0xFF8B867C);
  const dividerColor = Color(0xFFE7E3DA);
  const errorColor = Color(0xFFB64848);
  const fontFamily = 'NotoSansSC';

  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.light,
      ).copyWith(
        primary: primaryColor,
        onPrimary: Colors.white,
        secondary: primarySoftColor,
        onSecondary: textColor,
        surface: surfaceColor,
        onSurface: textColor,
        outline: dividerColor,
        error: errorColor,
        onError: Colors.white,
      );

  final baseTheme = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: scaffoldColor,
    fontFamily: fontFamily,
  );

  TextStyle style({
    required Color color,
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      letterSpacing: 0,
      height: 1.25,
    );
  }

  final textTheme = baseTheme.textTheme.copyWith(
    headlineMedium: style(
      color: textColor,
      fontSize: 30,
      fontWeight: FontWeight.w700,
    ),
    titleLarge: style(
      color: textColor,
      fontSize: 22,
      fontWeight: FontWeight.w700,
    ),
    titleMedium: style(
      color: textColor,
      fontSize: 18,
      fontWeight: FontWeight.w700,
    ),
    bodyLarge: style(color: textColor, fontSize: 15),
    bodyMedium: style(color: textColor, fontSize: 14),
    bodySmall: style(color: mutedTextColor, fontSize: 12),
    labelLarge: style(
      color: textColor,
      fontSize: 14,
      fontWeight: FontWeight.w700,
    ),
  );

  return baseTheme.copyWith(
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: scaffoldColor,
      foregroundColor: textColor,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: style(
        color: textColor,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: surfaceColor,
      elevation: 0,
      shadowColor: Colors.black.withValues(alpha: 0.05),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceColor,
      hintStyle: style(color: mutedTextColor, fontSize: 14),
      labelStyle: style(color: mutedTextColor, fontSize: 14),
      prefixIconColor: mutedTextColor,
      suffixIconColor: mutedTextColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: primaryColor, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: errorColor),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: errorColor, width: 1.4),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        disabledBackgroundColor: primaryColor.withValues(alpha: 0.45),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.9),
        minimumSize: const Size.fromHeight(56),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: style(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: primaryColor,
      foregroundColor: Colors.white,
      elevation: 0,
      shape: CircleBorder(),
    ),
    dividerColor: dividerColor,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: textColor,
      contentTextStyle: style(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.zero,
      iconColor: textColor,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: primaryColor,
      linearTrackColor: Color(0xFFE7E3DA),
      circularTrackColor: Color(0xFFE7E3DA),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return Colors.white;
        }
        return const Color(0xFFF5F4F1);
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return primaryColor;
        }
        return const Color(0xFFE7E3DA);
      }),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: const BorderSide(color: mutedTextColor, width: 1.2),
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return primaryColor;
        }
        return Colors.transparent;
      }),
    ),
  );
}
