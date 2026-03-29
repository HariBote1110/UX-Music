import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album.dart';
import '../models/song.dart';
import '../providers/download_provider.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../services/download_manager.dart';
import '../widgets/artwork_image.dart';
import '../widgets/song_tile.dart';
import 'album_detail_screen.dart';

enum _ViewMode { songs, albums }

class RemoteLibraryScreen extends ConsumerStatefulWidget {
  const RemoteLibraryScreen({super.key});

  @override
  ConsumerState<RemoteLibraryScreen> createState() =>
      _RemoteLibraryScreenState();
}

class _RemoteLibraryScreenState extends ConsumerState<RemoteLibraryScreen> {
  _ViewMode _viewMode = _ViewMode.albums;
  String _query = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(libraryProvider.notifier).refresh();
      ref.read(loudnessMapProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final libraryState = ref.watch(libraryProvider);

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(transitionBetweenRoutes: false,
        middle: const Text('Remote Library'),
        backgroundColor: const Color(0xFF1C1C1E),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 84,
              child: CupertinoSlidingSegmentedControl<_ViewMode>(
                groupValue: _viewMode,
                children: const {
                  _ViewMode.albums: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5),
                    child: Icon(CupertinoIcons.square_grid_2x2, size: 15),
                  ),
                  _ViewMode.songs: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5),
                    child: Icon(CupertinoIcons.list_bullet, size: 15),
                  ),
                },
                onValueChanged: (v) => setState(() => _viewMode = v!),
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.only(left: 4),
              minimumSize: Size.zero,
              onPressed: () {
                ref.read(libraryProvider.notifier).refresh();
                ref.read(loudnessMapProvider.notifier).refresh();
              },
              child: const Icon(CupertinoIcons.refresh, size: 19),
            ),
          ],
        ),
      ),
      child: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: CupertinoSearchTextField(
              placeholder: 'Search…',
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
            ),
          ),
          Expanded(
            child: libraryState.when(
              loading: () =>
                  const Center(child: CupertinoActivityIndicator(radius: 14)),
              error: (e, _) => _ErrorView(
                onRetry: () => ref.read(libraryProvider.notifier).refresh(),
              ),
              data: (songs) {
                final filtered = _filter(songs);
                if (filtered.isEmpty) {
                  return _EmptyView(noServer: songs.isEmpty);
                }
                return _viewMode == _ViewMode.albums
                    ? _AlbumsGrid(songs: filtered, query: _query)
                    : _SongsList(songs: filtered);
              },
            ),
          ),
        ],
      ),
    );
  }

  List<Song> _filter(List<Song> songs) {
    if (_query.isEmpty) return songs;
    return songs.where((s) {
      return s.title.toLowerCase().contains(_query) ||
          s.artist.toLowerCase().contains(_query) ||
          s.album.toLowerCase().contains(_query);
    }).toList();
  }
}

// ─── Albums Grid ─────────────────────────────────────────────────────────────

class _AlbumsGrid extends ConsumerWidget {
  const _AlbumsGrid({required this.songs, required this.query});

  final List<Song> songs;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(apiClientProvider);
    final albums = Album.fromSongs(songs);

    return GridView.builder(
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
        return _AlbumCard(
          album: album,
          artworkUrl: client.artworkUrl(album.artworkId),
        );
      },
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.artworkUrl});

  final Album album;
  final String artworkUrl;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        CupertinoPageRoute(builder: (_) => AlbumDetailScreen(album: album)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Artwork
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
            album.displayArtist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: CupertinoColors.systemGrey),
          ),
        ],
      ),
    );
  }
}

// ─── Songs List ───────────────────────────────────────────────────────────────

class _SongsList extends ConsumerWidget {
  const _SongsList({required this.songs});

  final List<Song> songs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(apiClientProvider);
    final downloadManager = ref.watch(downloadManagerProvider);
    final downloadProgress = ref.watch(downloadProgressProvider);
    final player = ref.read(musicPlayerProvider);

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      physics: const BouncingScrollPhysics(),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final song = songs[index];
        final isDownloaded = downloadManager.isDownloaded(song.id);
        final progress = downloadProgress[song.id];

        return SongTile(
          song: song,
          artworkUrl: client.artworkUrl(song.artworkId),
          trailing: _trailing(
            isDownloaded: isDownloaded,
            progress: progress,
            onDownload: () =>
                ref.read(downloadProgressProvider.notifier).download(song),
          ),
          onTap: isDownloaded
              ? () => _playLocal(player, downloadManager, song, songs)
              : null,
        );
      },
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
      return SizedBox(
        width: 20,
        height: 20,
        child: CupertinoActivityIndicator(
          radius: progress > 0 ? 10 : 10,
        ),
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

// ─── Helpers ─────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.wifi_slash,
            size: 48,
            color: CupertinoColors.systemGrey,
          ),
          const SizedBox(height: 12),
          const Text(
            'Failed to load library',
            style: TextStyle(color: CupertinoColors.systemGrey),
          ),
          const SizedBox(height: 8),
          CupertinoButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.noServer});
  final bool noServer;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        noServer ? 'No songs on server' : 'No matching songs',
        style: const TextStyle(color: CupertinoColors.systemGrey),
      ),
    );
  }
}
