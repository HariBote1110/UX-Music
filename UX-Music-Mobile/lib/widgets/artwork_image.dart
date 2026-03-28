import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class ArtworkImage extends StatelessWidget {
  const ArtworkImage({
    super.key,
    required this.url,
    this.size = 48,
  });

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => _placeholder(),
        errorWidget: (_, _, _) => _placeholder(),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: Colors.grey[800],
      child: Icon(Icons.music_note, size: size * 0.5, color: Colors.grey[600]),
    );
  }
}
