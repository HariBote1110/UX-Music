import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/song.dart';
import '../services/api_client.dart';
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
  (ref) => DownloadProgressNotifier(
    ref.read(apiClientProvider),
    ref.read(downloadManagerProvider),
  ),
);

class DownloadProgressNotifier extends StateNotifier<Map<String, double>> {
  DownloadProgressNotifier(this._client, this._manager) : super({});

  final ApiClient _client;
  final DownloadManager _manager;

  bool isDownloading(String songId) => state.containsKey(songId);

  Future<void> download(Song song) async {
    if (state.containsKey(song.id)) return; // already downloading
    state = {...state, song.id: 0.0};

    try {
      await _client.downloadFile(
        song.id,
        onProgress: (received, total) {
          if (total > 0) {
            state = {...state, song.id: received / total};
          }
        },
      );
      await _manager.register(song);
    } finally {
      state = Map.from(state)..remove(song.id);
    }
  }
}
