import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class ArtworkImage extends StatelessWidget {
  const ArtworkImage({
    super.key,
    required this.url,
    this.size = 48,
    this.fit = BoxFit.cover,
  });

  final String url;
  final double size;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _placeholder();

    final isFiniteSize = size != double.infinity;

    Widget image = CachedNetworkImage(
      imageUrl: url,
      width: isFiniteSize ? size : null,
      height: isFiniteSize ? size : null,
      fit: fit,
      placeholder: (_, _) => _placeholder(),
      errorWidget: (_, _, _) => _placeholder(),
    );

    if (isFiniteSize) {
      image = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: image,
      );
    }

    return image;
  }

  Widget _placeholder() {
    final s = size == double.infinity ? 48.0 : size;
    return Container(
      width: s == double.infinity ? null : s,
      height: s == double.infinity ? null : s,
      color: Colors.grey[800],
      child: Icon(Icons.music_note, size: s * 0.5, color: Colors.grey[600]),
    );
  }
}
