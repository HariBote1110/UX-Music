import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album.dart';
import '../models/song.dart';
import '../providers/download_provider.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/download_manager.dart';
import '../widgets/artwork_image.dart';
import '../widgets/song_tile.dart';

class AlbumDetailScreen extends ConsumerWidget {
  const AlbumDetailScreen({super.key, required this.album});

  final Album album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(apiClientProvider);
    final downloadManager = ref.watch(downloadManagerProvider);
    final downloadProgress = ref.watch(downloadProgressProvider);
    final player = ref.read(musicPlayerProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            backgroundColor: const Color(0xFF1C1C1E),
            // Use the Cupertino back button style
            leading: CupertinoButton(
              padding: const EdgeInsets.only(left: 8),
              child: const Icon(CupertinoIcons.back, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                album.displayName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  album.artworkId.isNotEmpty
                      ? ArtworkImage(
                          url: client.artworkUrl(album.artworkId),
                          size: double.infinity,
                          fit: BoxFit.cover,
                        )
                      : Container(color: Colors.grey[900]),
                  // Gradient overlay
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black87],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      album.displayArtist,
                      style: const TextStyle(
                        color: CupertinoColors.systemGrey,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Text(
                    '${album.songs.length} songs',
                    style: const TextStyle(
                      color: CupertinoColors.systemGrey2,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final song = album.songs[index];
                final isDownloaded = downloadManager.isDownloaded(song.id);
                final progress = downloadProgress[song.id];

                return SongTile(
                  song: song,
                  artworkUrl: client.artworkUrl(song.artworkId),
                  showTrackNumber: true,
                  trailing: _trailing(
                    isDownloaded: isDownloaded,
                    progress: progress,
                    onDownload: () => ref
                        .read(downloadProgressProvider.notifier)
                        .download(song),
                  ),
                  onTap: isDownloaded
                      ? () =>
                          _playLocal(player, downloadManager, song, album.songs)
                      : null,
                );
              },
              childCount: album.songs.length,
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
        ],
      ),
    );
  }

  Widget _trailing({
    required bool isDownloaded,
    required double? progress,
    required VoidCallback onDownload,
  }) {
    if (isDownloaded) {
      return const Icon(
        CupertinoIcons.checkmark_circle_fill,
        color: CupertinoColors.systemGreen,
        size: 20,
      );
    }
    if (progress != null) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CupertinoActivityIndicator(radius: 10),
      );
    }
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(32, 32),
      onPressed: onDownload,
      child: const Icon(CupertinoIcons.arrow_down_circle, size: 22),
    );
  }

  void _playLocal(
    dynamic player,
    DownloadManager dm,
    Song song,
    List<Song> allSongs,
  ) {
    final downloaded = allSongs.where((s) => dm.isDownloaded(s.id)).toList();
    final localSong = song.copyWith(path: dm.localPath(song.id));
    final localQueue =
        downloaded.map((s) => s.copyWith(path: dm.localPath(s.id))).toList();
    player.play(localSong, newQueue: localQueue);
  }
}
