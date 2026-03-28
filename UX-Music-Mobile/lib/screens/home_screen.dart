import 'package:flutter/material.dart';

import '../widgets/glass_nav_bar.dart';
import '../widgets/mini_player.dart';
import 'local_library_screen.dart';
import 'remote_library_screen.dart';
import 'remote_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _screens = [
    LocalLibraryScreen(),
    RemoteLibraryScreen(),
    RemoteScreen(),
    SettingsScreen(),
  ];

  static const _navItems = [
    GlassNavBarItem(
      icon: Icons.library_music_outlined,
      activeIcon: Icons.library_music,
      label: 'Library',
    ),
    GlassNavBarItem(
      icon: Icons.wifi_outlined,
      activeIcon: Icons.wifi,
      label: 'Remote',
    ),
    GlassNavBarItem(
      icon: Icons.desktop_mac_outlined,
      activeIcon: Icons.desktop_mac,
      label: 'Control',
    ),
    GlassNavBarItem(
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings,
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Allow content to render behind the floating glass nav bar
      extendBody: true,
      body: Stack(
        children: [
          IndexedStack(
            index: _index,
            children: _screens,
          ),
          // Mini player sits just above the nav bar
          Positioned(
            left: 0,
            right: 0,
            bottom: _navBarHeight(context),
            child: const MiniPlayer(),
          ),
        ],
      ),
      bottomNavigationBar: GlassNavBar(
        items: _navItems,
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }

  double _navBarHeight(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    // Glass nav bar: 12 top + 12 bottom + 22 icon + bottomPadding
    return bottomPadding + 46;
  }
}
