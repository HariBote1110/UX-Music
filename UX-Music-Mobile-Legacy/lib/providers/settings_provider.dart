import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/server_config.dart';

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, ServerConfig>((ref) {
  return SettingsNotifier();
});

class SettingsNotifier extends StateNotifier<ServerConfig> {
  SettingsNotifier() : super(const ServerConfig()) {
    _load();
  }

  static const _key = 'server_config';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      state = ServerConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    }
  }

  Future<void> update({String? host, int? port}) async {
    state = state.copyWith(
      host: host ?? state.host,
      port: port ?? state.port,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state.toJson()));
  }
}

final targetLoudnessProvider = StateProvider<double>(
  (_) => kDefaultTargetLoudness,
);
