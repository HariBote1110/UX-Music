import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../widgets/artwork_image.dart';

class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(musicPlayerProvider);
    final client = ref.watch(apiClientProvider);
    final song = player.currentSong;

    if (song == null) {
      return const CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          transitionBetweenRoutes: false,
        ),
        child: Center(child: Text('No song playing')),
      );
    }

    return CupertinoPageScaffold(
      // Transparent nav bar — back button floats above the artwork
      navigationBar: const CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        backgroundColor: Colors.transparent,
        border: null,
      ),
      backgroundColor: Colors.black,
      // DefaultTextStyle reset: CupertinoPageScaffold does not inherit the
      // Material DefaultTextStyle, causing text to render red / with underlines.
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.white,
          decoration: TextDecoration.none,
          fontFamily: '.SF Pro Text',
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Spacer(),
                // Artwork
                ArtworkImage(url: client.artworkUrl(song.artworkId), size: 280),
                const SizedBox(height: 32),
                // Title
                Text(
                  song.displayTitle,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                // Artist
                Text(
                  song.displayArtist,
                  style: const TextStyle(
                    fontSize: 16,
                    color: CupertinoColors.systemGrey,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                // Seek bar — combine both streams to avoid nested StreamBuilders
                _SeekBar(player: player),
                const SizedBox(height: 16),
                // Playback controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => player.previous(),
                      child: const Icon(
                        CupertinoIcons.backward_end_fill,
                        size: 38,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 24),
                    StreamBuilder<PlayerState>(
                      stream: player.playerStateStream,
                      builder: (context, snap) {
                        final playing = snap.data?.playing ?? false;
                        return CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () => player.togglePlayPause(),
                          child: Icon(
                            playing
                                ? CupertinoIcons.pause_circle_fill
                                : CupertinoIcons.play_circle_fill,
                            size: 72,
                            color: Colors.white,
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 24),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => player.next(),
                      child: const Icon(
                        CupertinoIcons.forward_end_fill,
                        size: 38,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Seek bar widget that listens to both position and duration streams.
class _SeekBar extends StatelessWidget {
  const _SeekBar({required this.player});

  final dynamic player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: player.positionStream,
      builder: (context, posSnap) {
        return StreamBuilder<Duration?>(
          stream: player.durationStream,
          builder: (context, durSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final dur = durSnap.data ?? Duration.zero;
            final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // SizedBox.expand equivalent — force slider to full width
                SizedBox(
                  width: double.infinity,
                  child: CupertinoSlider(
                    value: pos.inMilliseconds
                        .toDouble()
                        .clamp(0.0, maxMs.toDouble()),
                    max: maxMs.toDouble(),
                    activeColor: Colors.white,
                    thumbColor: Colors.white,
                    onChanged: (v) =>
                        player.seek(Duration(milliseconds: v.toInt())),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _fmt(pos),
                        style: const TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                      Text(
                        _fmt(dur),
                        style: const TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.systemGrey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
