import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album.dart';
import '../providers/download_provider.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../widgets/artwork_image.dart';
import '../widgets/song_tile.dart';

enum _ViewMode { songs, albums }

class LocalLibraryScreen extends ConsumerStatefulWidget {
  const LocalLibraryScreen({super.key});

  @override
  ConsumerState<LocalLibraryScreen> createState() => _LocalLibraryScreenState();
}

class _LocalLibraryScreenState extends ConsumerState<LocalLibraryScreen> {
  _ViewMode _viewMode = _ViewMode.albums;

  @override
  Widget build(BuildContext context) {
    final dm = ref.watch(downloadManagerProvider);
    final client = ref.watch(apiClientProvider);
    final player = ref.read(musicPlayerProvider);
    final songs = dm.downloadedSongs.values.toList();

    if (songs.isEmpty) {
      return CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(transitionBetweenRoutes: false,
          middle: Text('Library'),
          backgroundColor: Color(0xFF1C1C1E),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.music_albums, size: 64, color: Colors.grey[700]),
              const SizedBox(height: 16),
              Text(
                'No downloaded songs',
                style: TextStyle(color: Colors.grey[400], fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                'Download songs from Remote Library',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final albums = Album.fromSongs(songs);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(transitionBetweenRoutes: false,
        middle: Text('Library (${songs.length})'),
        backgroundColor: const Color(0xFF1C1C1E),
        trailing: SizedBox(
          width: 88,
          child: CupertinoSlidingSegmentedControl<_ViewMode>(
            groupValue: _viewMode,
            children: const {
              _ViewMode.albums: Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(CupertinoIcons.square_grid_2x2, size: 15),
              ),
              _ViewMode.songs: Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(CupertinoIcons.list_bullet, size: 15),
              ),
            },
            onValueChanged: (v) => setState(() => _viewMode = v!),
          ),
        ),
      ),
      child: _viewMode == _ViewMode.albums
          ? GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
              physics: const BouncingScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.78,
              ),
              itemCount: albums.length,
              itemBuilder: (context, index) {
                final album = albums[index];
                return _LocalAlbumCard(
                  album: album,
                  artworkUrl: client.artworkUrl(album.artworkId),
                  onTap: () {
                    final dm2 = ref.read(downloadManagerProvider);
                    final first = album.songs.first;
                    final localSong =
                        first.copyWith(path: dm2.localPath(first.id));
                    final localQueue = album.songs
                        .map((s) => s.copyWith(path: dm2.localPath(s.id)))
                        .toList();
                    player.play(localSong, newQueue: localQueue);
                  },
                );
              },
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 100),
              physics: const BouncingScrollPhysics(),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final song = songs[index];
                return Dismissible(
                  key: ValueKey(song.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    color: CupertinoColors.destructiveRed,
                    child: const Icon(CupertinoIcons.trash, color: Colors.white),
                  ),
                  onDismissed: (_) => dm.remove(song.id),
                  child: SongTile(
                    song: song,
                    artworkUrl: client.artworkUrl(song.artworkId),
                    onTap: () {
                      final localSong =
                          song.copyWith(path: dm.localPath(song.id));
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

class _LocalAlbumCard extends StatelessWidget {
  const _LocalAlbumCard({
    required this.album,
    required this.artworkUrl,
    required this.onTap,
  });

  final Album album;
  final String artworkUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 1,
              child: ArtworkImage(url: artworkUrl, size: double.infinity),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            album.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          Text(
            '${album.displayArtist} · ${album.songs.length} songs',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: CupertinoColors.systemGrey),
          ),
        ],
      ),
    );
  }
}
