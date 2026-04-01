import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/download_manager.dart';
import 'library_provider.dart';

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final manager = DownloadManager();
  manager.init();
  return manager;
});

/// Tracks download progress: songID → progress (0.0 to 1.0), or null if not downloading.
final downloadProgressProvider =
    StateNotifierProvider<DownloadProgressNotifier, Map<String, double>>(
  // Pass Ref directly so the notifier always reads the latest ApiClient
  (ref) => DownloadProgressNotifier(ref),
);

class DownloadProgressNotifier extends StateNotifier<Map<String, double>> {
  DownloadProgressNotifier(this._ref) : super({});

  final Ref _ref;

  bool isDownloading(String songId) => state.containsKey(songId);

  Future<void> download(Song song) async {
    if (state.containsKey(song.id)) return; // already downloading
    state = {...state, song.id: 0.0};

    final client = _ref.read(apiClientProvider);
    final manager = _ref.read(downloadManagerProvider);

    try {
      await client.downloadFile(
        song.id,
        onProgress: (received, total) {
          if (total > 0) {
            state = {...state, song.id: received / total};
          }
        },
      );
      await manager.register(song);
    } finally {
      state = Map.from(state)..remove(song.id);
    }
  }
}
