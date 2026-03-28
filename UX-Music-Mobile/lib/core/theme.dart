import 'package:flutter/material.dart';

/// iOS-inspired dark theme.
/// Uses Material infrastructure (required by GlassNavBar, SliverAppBar etc.)
/// but configures colours and transitions to feel native on iOS.
final ThemeData appTheme = ThemeData(
  brightness: Brightness.dark,
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFF0A84FF), // iOS system blue (dark mode)
    secondary: Color(0xFF30D158), // iOS system green
    surface: Color(0xFF1C1C1E), // iOS secondary background
    error: Color(0xFFFF453A), // iOS system red
  ),
  scaffoldBackgroundColor: Colors.black,
  useMaterial3: true,
  // Use Cupertino page transitions on all platforms
  pageTransitionsTheme: const PageTransitionsTheme(
    builders: {
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    },
  ),
);

/// Forces iOS-style bouncing scroll physics on all scrollable widgets.
class BouncingScrollBehaviour extends ScrollBehavior {
  const BouncingScrollBehaviour();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics();
}
