import 'song.dart';

/// A grouping of songs by album, derived from the library.
class Album {
  Album({
    required this.name,
    required this.artistName,
    required this.artworkId,
    required this.songs,
  });

  final String name;
  final String artistName;
  final String artworkId;
  final List<Song> songs;

  String get displayName => name.isEmpty ? 'Unknown Album' : name;
  String get displayArtist => artistName.isEmpty ? 'Unknown Artist' : artistName;

  /// Build an album list from a flat song list, sorted by album name.
  static List<Album> fromSongs(List<Song> songs) {
    final map = <String, Album>{};

    for (final song in songs) {
      final key = '${song.albumArtist.isEmpty ? song.artist : song.albumArtist}___${song.album}';
      if (map.containsKey(key)) {
        map[key]!.songs.add(song);
      } else {
        map[key] = Album(
          name: song.album,
          artistName: song.albumArtist.isEmpty ? song.artist : song.albumArtist,
          artworkId: song.artworkId,
          songs: [song],
        );
      }
    }

    final albums = map.values.toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    // Sort songs inside each album by disc/track number
    for (final album in albums) {
      album.songs.sort((a, b) {
        final disc = a.discNumber.compareTo(b.discNumber);
        return disc != 0 ? disc : a.trackNumber.compareTo(b.trackNumber);
      });
    }

    return albums;
  }
}
