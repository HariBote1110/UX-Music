import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/api_client.dart';
import 'settings_provider.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(settingsProvider);
  return ApiClient(config.baseUrl);
});

final libraryProvider =
    AsyncNotifierProvider<LibraryNotifier, List<Song>>(LibraryNotifier.new);

class LibraryNotifier extends AsyncNotifier<List<Song>> {
  @override
  Future<List<Song>> build() async => [];

  Future<void> refresh() async {
    state = const AsyncLoading();
    try {
      final client = ref.read(apiClientProvider);
      final songs = await client.fetchSongs();
      state = AsyncData(songs);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}

final loudnessMapProvider =
    AsyncNotifierProvider<LoudnessNotifier, Map<String, double>>(
        LoudnessNotifier.new);

class LoudnessNotifier extends AsyncNotifier<Map<String, double>> {
  @override
  Future<Map<String, double>> build() async => {};

  Future<void> refresh() async {
    try {
      final client = ref.read(apiClientProvider);
      final map = await client.fetchLoudness();
      state = AsyncData(map);
    } catch (_) {
      // Keep previous data on error
    }
  }
}
