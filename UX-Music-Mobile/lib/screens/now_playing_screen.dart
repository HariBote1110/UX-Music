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
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('No song playing')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          children: [
            const Spacer(),
            // Artwork
            ArtworkImage(url: client.artworkUrl(song.id), size: 280),
            const SizedBox(height: 32),
            // Title / Artist
            Text(
              song.displayTitle,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              song.displayArtist,
              style: TextStyle(fontSize: 16, color: Colors.grey[400]),
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
                        Slider(
                          value: pos.inMilliseconds
                              .toDouble()
                              .clamp(0, maxVal.toDouble()),
                          max: maxVal.toDouble(),
                          onChanged: (v) =>
                              player.seek(Duration(milliseconds: v.toInt())),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_formatDuration(pos),
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey[400])),
                              Text(_formatDuration(dur),
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey[400])),
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
            // Controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 36,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () => player.previous(),
                ),
                const SizedBox(width: 24),
                StreamBuilder<PlayerState>(
                  stream: player.playerStateStream,
                  builder: (context, snap) {
                    final playing = snap.data?.playing ?? false;
                    return IconButton(
                      iconSize: 64,
                      icon: Icon(playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled),
                      onPressed: () => player.togglePlayPause(),
                    );
                  },
                ),
                const SizedBox(width: 24),
                IconButton(
                  iconSize: 36,
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => player.next(),
                ),
              ],
            ),
            const Spacer(),
          ],
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
