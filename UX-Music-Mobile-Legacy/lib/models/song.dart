import 'package:freezed_annotation/freezed_annotation.dart';

part 'song.freezed.dart';
part 'song.g.dart';

/// Mirrors the Go scanner.Song struct (internal/scanner/scanner.go:14-31).
/// JSON keys match the Go json tags exactly.
@freezed
abstract class Song with _$Song {
  const factory Song({
    required String id,
    required String path,
    @Default('') String title,
    @Default('') String artist,
    @Default('') String album,
    @JsonKey(name: 'albumartist') @Default('') String albumArtist,
    @Default(0) int year,
    @Default('') String genre,
    @Default(0.0) double duration,
    @Default(0) int trackNumber,
    @Default(0) int discNumber,
    @Default(0) int fileSize,
    @Default('') String fileType,
    int? sampleRate,
    int? bitDepth,
    // SHA256 hash of "albumArtist---album" — used to construct artwork URLs.
    // Added by the /wear/songs endpoint; null on older server versions.
    @JsonKey(name: 'artworkId') @Default('') String artworkId,
  }) = _Song;

  const Song._();

  factory Song.fromJson(Map<String, dynamic> json) => _$SongFromJson(json);

  String get displayTitle => title.isEmpty ? 'Unknown Title' : title;
  String get displayArtist => artist.isEmpty ? 'Unknown Artist' : artist;
  String get displayAlbum => album.isEmpty ? 'Unknown Album' : album;

  String get formattedDuration {
    final minutes = duration ~/ 60;
    final seconds = (duration % 60).truncate();
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
