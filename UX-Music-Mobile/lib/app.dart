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
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
