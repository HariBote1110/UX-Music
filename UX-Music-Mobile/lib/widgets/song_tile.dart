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
  });

  final Song song;
  final String artworkUrl;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ArtworkImage(url: artworkUrl),
      title: Text(
        song.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${song.displayArtist} · ${song.formattedDuration}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.grey[400], fontSize: 13),
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
