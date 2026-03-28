// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'song.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Song _$SongFromJson(Map<String, dynamic> json) => _Song(
  id: json['id'] as String,
  path: json['path'] as String,
  title: json['title'] as String? ?? '',
  artist: json['artist'] as String? ?? '',
  album: json['album'] as String? ?? '',
  albumArtist: json['albumartist'] as String? ?? '',
  year: (json['year'] as num?)?.toInt() ?? 0,
  genre: json['genre'] as String? ?? '',
  duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
  trackNumber: (json['trackNumber'] as num?)?.toInt() ?? 0,
  discNumber: (json['discNumber'] as num?)?.toInt() ?? 0,
  fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
  fileType: json['fileType'] as String? ?? '',
  sampleRate: (json['sampleRate'] as num?)?.toInt(),
  bitDepth: (json['bitDepth'] as num?)?.toInt(),
);

Map<String, dynamic> _$SongToJson(_Song instance) => <String, dynamic>{
  'id': instance.id,
  'path': instance.path,
  'title': instance.title,
  'artist': instance.artist,
  'album': instance.album,
  'albumartist': instance.albumArtist,
  'year': instance.year,
  'genre': instance.genre,
  'duration': instance.duration,
  'trackNumber': instance.trackNumber,
  'discNumber': instance.discNumber,
  'fileSize': instance.fileSize,
  'fileType': instance.fileType,
  'sampleRate': instance.sampleRate,
  'bitDepth': instance.bitDepth,
};
