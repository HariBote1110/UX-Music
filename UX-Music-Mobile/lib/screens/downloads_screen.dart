import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/download_provider.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../widgets/song_tile.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dm = ref.watch(downloadManagerProvider);
    final client = ref.watch(apiClientProvider);
    final player = ref.read(musicPlayerProvider);
    final songs = dm.downloadedSongs.values.toList();

    if (songs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Downloads')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_done, size: 48, color: Colors.grey[600]),
              const SizedBox(height: 12),
              Text('No downloaded songs', style: TextStyle(color: Colors.grey[400])),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('Downloads (${songs.length})')),
      body: ListView.builder(
        itemCount: songs.length,
        itemBuilder: (context, index) {
          final song = songs[index];
          return Dismissible(
            key: ValueKey(song.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              color: Colors.red,
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) => dm.remove(song.id),
            child: SongTile(
              song: song,
              artworkUrl: client.artworkUrl(song.id),
              onTap: () {
                final localSong = song.copyWith(path: dm.localPath(song.id));
                final localQueue = songs
                    .map((s) => s.copyWith(path: dm.localPath(s.id)))
                    .toList();
                player.play(localSong, newQueue: localQueue);
              },
            ),
          );
        },
      ),
    );
  }
}
