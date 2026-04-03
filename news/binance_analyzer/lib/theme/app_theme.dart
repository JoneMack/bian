import 'package:flutter/material.dart';

class AppTheme {
  // Binance 官方配色
  static const Color binanceYellow = Color(0xFFF0B90B);
  static const Color binanceDark = Color(0xFF0B0E11);
  static const Color cardDark = Color(0xFF1E2026);
  static const Color cardLight = Color(0xFF2B2F36);
  static const Color textPrimary = Color(0xFFEAECEF);
  static const Color textSecondary = Color(0xFF848E9C);
  static const Color green = Color(0xFF0ECB81);
  static const Color red = Color(0xFFF6465D);
  static const Color accentBlue = Color(0xFF4DA3FF);
  static const Color accentOrange = Color(0xFFFF8A3D);
  static const Color strongBuyColor = Color(0xFF00C087);
  static const Color buyColor = Color(0xFF0ECB81);
  static const Color holdColor = Color(0xFFF0B90B);
  static const Color avoidColor = Color(0xFFF6465D);

  static BoxDecoration panelDecoration({Color? borderColor}) {
    return BoxDecoration(
      color: cardDark,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: (borderColor ?? cardLight).withAlpha(170)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x24000000),
          blurRadius: 24,
          offset: Offset(0, 12),
        ),
      ],
    );
  }

  static Color scoreColor(double score) {
    if (score >= 0.72) return strongBuyColor;
    if (score >= 0.58) return buyColor;
    if (score >= 0.42) return holdColor;
    return avoidColor;
  }

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        primaryColor: binanceYellow,
        scaffoldBackgroundColor: binanceDark,
        colorScheme: const ColorScheme.dark(
          primary: binanceYellow,
          secondary: binanceYellow,
          surface: cardDark,
          onSurface: textPrimary,
          onPrimary: binanceDark,
        ),
        cardColor: cardDark,
        cardTheme: const CardThemeData(
          color: cardDark,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: binanceDark,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: textPrimary),
        ),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: textPrimary),
          bodyMedium: TextStyle(color: textSecondary),
          titleLarge:
              TextStyle(color: textPrimary, fontWeight: FontWeight.bold),
          titleMedium: TextStyle(color: textPrimary),
        ),
        dividerColor: cardLight,
        progressIndicatorTheme:
            const ProgressIndicatorThemeData(color: binanceYellow),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: cardLight,
          contentTextStyle: TextStyle(color: textPrimary),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: cardLight,
          labelStyle: const TextStyle(color: textPrimary, fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
      );
}
