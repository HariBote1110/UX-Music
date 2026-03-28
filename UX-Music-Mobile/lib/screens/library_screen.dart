import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/download_provider.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/download_manager.dart';
import '../widgets/song_tile.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Fetch library on first load
    Future.microtask(() => ref.read(libraryProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    final libraryState = ref.watch(libraryProvider);
    final downloads = ref.watch(downloadProgressProvider);
    final downloadManager = ref.watch(downloadManagerProvider);
    final client = ref.watch(apiClientProvider);
    final player = ref.read(musicPlayerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.read(libraryProvider.notifier).refresh();
              ref.read(loudnessMapProvider.notifier).refresh();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search songs…',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
            ),
          ),
          Expanded(
            child: libraryState.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
                    const SizedBox(height: 12),
                    Text('Failed to load library',
                        style: TextStyle(color: Colors.grey[400])),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(libraryProvider.notifier).refresh(),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              data: (songs) {
                final filtered = _query.isEmpty
                    ? songs
                    : songs.where((s) {
                        final q = _query;
                        return s.title.toLowerCase().contains(q) ||
                            s.artist.toLowerCase().contains(q) ||
                            s.album.toLowerCase().contains(q);
                      }).toList();

                if (filtered.isEmpty) {
                  return Center(
                    child: Text(
                      songs.isEmpty
                          ? 'No songs on server'
                          : 'No matching songs',
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final song = filtered[index];
                    final isDownloaded = downloadManager.isDownloaded(song.id);
                    final progress = downloads[song.id];

                    return SongTile(
                      song: song,
                      artworkUrl: client.artworkUrl(song.id),
                      trailing: _buildTrailingWidget(
                        isDownloaded: isDownloaded,
                        progress: progress,
                        onDownload: () => ref
                            .read(downloadProgressProvider.notifier)
                            .download(song),
                      ),
                      onTap: isDownloaded
                          ? () => _playLocal(player, downloadManager, song, filtered)
                          : null,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrailingWidget({
    required bool isDownloaded,
    required double? progress,
    required VoidCallback onDownload,
  }) {
    if (isDownloaded) {
      return const Icon(Icons.check_circle, color: Colors.green, size: 20);
    }
    if (progress != null) {
      return SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          value: progress > 0 ? progress : null,
          strokeWidth: 2,
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download),
      iconSize: 20,
      onPressed: onDownload,
    );
  }

  void _playLocal(
    dynamic player,
    DownloadManager dm,
    dynamic song,
    List<dynamic> allSongs,
  ) {
    // Build a queue of downloaded songs and play the selected one
    final downloadedSongs = allSongs.where((s) => dm.isDownloaded(s.id)).toList();
    // Create a copy with local path for playback
    final localSong = song.copyWith(path: dm.localPath(song.id));
    final localQueue = downloadedSongs
        .map((s) => s.copyWith(path: dm.localPath(s.id)))
        .toList();
    player.play(localSong, newQueue: localQueue);
  }
}
