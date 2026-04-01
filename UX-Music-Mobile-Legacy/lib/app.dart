import 'package:flutter/material.dart';

import 'core/theme.dart';
import 'screens/home_screen.dart';

class UxMusicApp extends StatelessWidget {
  const UxMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UX Music',
      theme: appTheme,
      // Bouncing physics on every scrollable widget
      scrollBehavior: const BouncingScrollBehaviour(),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
