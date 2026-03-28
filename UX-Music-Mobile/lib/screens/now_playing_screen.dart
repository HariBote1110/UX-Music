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
        navigationBar: CupertinoNavigationBar(transitionBetweenRoutes: false,),
        child: Center(child: Text('No song playing')),
      );
    }

    return CupertinoPageScaffold(
      // Transparent nav bar so the back button floats over the content
      navigationBar: const CupertinoNavigationBar(transitionBetweenRoutes: false,
        backgroundColor: Colors.transparent,
        border: null,
      ),
      backgroundColor: Colors.black,
      child: SafeArea(
        top: false, // CupertinoPageScaffold already offsets for nav bar
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(),
              // Artwork
              ArtworkImage(url: client.artworkUrl(song.artworkId), size: 280),
              const SizedBox(height: 32),
              // Title
              Text(
                song.displayTitle,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
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
              // Seek bar
              StreamBuilder<Duration?>(
                stream: player.positionStream,
                builder: (context, posSnap) {
                  return StreamBuilder<Duration?>(
                    stream: player.durationStream,
                    builder: (context, durSnap) {
                      final pos = posSnap.data ?? Duration.zero;
                      final dur = durSnap.data ?? Duration.zero;
                      final maxVal =
                          dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;

                      return Column(
                        children: [
                          CupertinoSlider(
                            value: pos.inMilliseconds
                                .toDouble()
                                .clamp(0, maxVal.toDouble()),
                            max: maxVal.toDouble(),
                            onChanged: (v) =>
                                player.seek(Duration(milliseconds: v.toInt())),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(pos),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: CupertinoColors.systemGrey,
                                  ),
                                ),
                                Text(
                                  _formatDuration(dur),
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
              ),
              const SizedBox(height: 16),
              // Playback controls
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    child: const Icon(
                      CupertinoIcons.backward_end_fill,
                      size: 38,
                    ),
                    onPressed: () => player.previous(),
                  ),
                  const SizedBox(width: 24),
                  StreamBuilder<PlayerState>(
                    stream: player.playerStateStream,
                    builder: (context, snap) {
                      final playing = snap.data?.playing ?? false;
                      return CupertinoButton(
                        padding: EdgeInsets.zero,
                        child: Icon(
                          playing
                              ? CupertinoIcons.pause_circle_fill
                              : CupertinoIcons.play_circle_fill,
                          size: 72,
                        ),
                        onPressed: () => player.togglePlayPause(),
                      );
                    },
                  ),
                  const SizedBox(width: 24),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    child: const Icon(
                      CupertinoIcons.forward_end_fill,
                      size: 38,
                    ),
                    onPressed: () => player.next(),
                  ),
                ],
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
