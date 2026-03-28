import 'package:flutter/material.dart';

import '../models/song.dart';
import 'artwork_image.dart';

class SongTile extends StatelessWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.artworkUrl,
    this.trailing,
    this.onTap,
    this.showTrackNumber = false,
  });

  final Song song;
  final String artworkUrl;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showTrackNumber;

  @override
  Widget build(BuildContext context) {
    Widget leading = showTrackNumber && song.trackNumber > 0
        ? SizedBox(
            width: 48,
            child: Center(
              child: Text(
                '${song.trackNumber}',
                style: TextStyle(fontSize: 15, color: Colors.grey[400]),
              ),
            ),
          )
        : ArtworkImage(url: artworkUrl);

    return ListTile(
      leading: leading,
      title: Text(
        song.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        showTrackNumber
            ? song.formattedDuration
            : '${song.displayArtist} · ${song.formattedDuration}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.grey[400], fontSize: 13),
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
