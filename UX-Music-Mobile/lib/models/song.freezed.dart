// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'song.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Song {

 String get id; String get path; String get title; String get artist; String get album;@JsonKey(name: 'albumartist') String get albumArtist; int get year; String get genre; double get duration; int get trackNumber; int get discNumber; int get fileSize; String get fileType; int? get sampleRate; int? get bitDepth;// SHA256 hash of "albumArtist---album" — used to construct artwork URLs.
// Added by the /wear/songs endpoint; null on older server versions.
@JsonKey(name: 'artworkId') String get artworkId;
/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SongCopyWith<Song> get copyWith => _$SongCopyWithImpl<Song>(this as Song, _$identity);

  /// Serializes this Song to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Song&&(identical(other.id, id) || other.id == id)&&(identical(other.path, path) || other.path == path)&&(identical(other.title, title) || other.title == title)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.album, album) || other.album == album)&&(identical(other.albumArtist, albumArtist) || other.albumArtist == albumArtist)&&(identical(other.year, year) || other.year == year)&&(identical(other.genre, genre) || other.genre == genre)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.trackNumber, trackNumber) || other.trackNumber == trackNumber)&&(identical(other.discNumber, discNumber) || other.discNumber == discNumber)&&(identical(other.fileSize, fileSize) || other.fileSize == fileSize)&&(identical(other.fileType, fileType) || other.fileType == fileType)&&(identical(other.sampleRate, sampleRate) || other.sampleRate == sampleRate)&&(identical(other.bitDepth, bitDepth) || other.bitDepth == bitDepth)&&(identical(other.artworkId, artworkId) || other.artworkId == artworkId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,path,title,artist,album,albumArtist,year,genre,duration,trackNumber,discNumber,fileSize,fileType,sampleRate,bitDepth,artworkId);

@override
String toString() {
  return 'Song(id: $id, path: $path, title: $title, artist: $artist, album: $album, albumArtist: $albumArtist, year: $year, genre: $genre, duration: $duration, trackNumber: $trackNumber, discNumber: $discNumber, fileSize: $fileSize, fileType: $fileType, sampleRate: $sampleRate, bitDepth: $bitDepth, artworkId: $artworkId)';
}


}

/// @nodoc
abstract mixin class $SongCopyWith<$Res>  {
  factory $SongCopyWith(Song value, $Res Function(Song) _then) = _$SongCopyWithImpl;
@useResult
$Res call({
 String id, String path, String title, String artist, String album,@JsonKey(name: 'albumartist') String albumArtist, int year, String genre, double duration, int trackNumber, int discNumber, int fileSize, String fileType, int? sampleRate, int? bitDepth,@JsonKey(name: 'artworkId') String artworkId
});




}
/// @nodoc
class _$SongCopyWithImpl<$Res>
    implements $SongCopyWith<$Res> {
  _$SongCopyWithImpl(this._self, this._then);

  final Song _self;
  final $Res Function(Song) _then;

/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? path = null,Object? title = null,Object? artist = null,Object? album = null,Object? albumArtist = null,Object? year = null,Object? genre = null,Object? duration = null,Object? trackNumber = null,Object? discNumber = null,Object? fileSize = null,Object? fileType = null,Object? sampleRate = freezed,Object? bitDepth = freezed,Object? artworkId = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,artist: null == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String,album: null == album ? _self.album : album // ignore: cast_nullable_to_non_nullable
as String,albumArtist: null == albumArtist ? _self.albumArtist : albumArtist // ignore: cast_nullable_to_non_nullable
as String,year: null == year ? _self.year : year // ignore: cast_nullable_to_non_nullable
as int,genre: null == genre ? _self.genre : genre // ignore: cast_nullable_to_non_nullable
as String,duration: null == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as double,trackNumber: null == trackNumber ? _self.trackNumber : trackNumber // ignore: cast_nullable_to_non_nullable
as int,discNumber: null == discNumber ? _self.discNumber : discNumber // ignore: cast_nullable_to_non_nullable
as int,fileSize: null == fileSize ? _self.fileSize : fileSize // ignore: cast_nullable_to_non_nullable
as int,fileType: null == fileType ? _self.fileType : fileType // ignore: cast_nullable_to_non_nullable
as String,sampleRate: freezed == sampleRate ? _self.sampleRate : sampleRate // ignore: cast_nullable_to_non_nullable
as int?,bitDepth: freezed == bitDepth ? _self.bitDepth : bitDepth // ignore: cast_nullable_to_non_nullable
as int?,artworkId: null == artworkId ? _self.artworkId : artworkId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [Song].
extension SongPatterns on Song {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Song value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Song() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Song value)  $default,){
final _that = this;
switch (_that) {
case _Song():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Song value)?  $default,){
final _that = this;
switch (_that) {
case _Song() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String path,  String title,  String artist,  String album, @JsonKey(name: 'albumartist')  String albumArtist,  int year,  String genre,  double duration,  int trackNumber,  int discNumber,  int fileSize,  String fileType,  int? sampleRate,  int? bitDepth, @JsonKey(name: 'artworkId')  String artworkId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Song() when $default != null:
return $default(_that.id,_that.path,_that.title,_that.artist,_that.album,_that.albumArtist,_that.year,_that.genre,_that.duration,_that.trackNumber,_that.discNumber,_that.fileSize,_that.fileType,_that.sampleRate,_that.bitDepth,_that.artworkId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String path,  String title,  String artist,  String album, @JsonKey(name: 'albumartist')  String albumArtist,  int year,  String genre,  double duration,  int trackNumber,  int discNumber,  int fileSize,  String fileType,  int? sampleRate,  int? bitDepth, @JsonKey(name: 'artworkId')  String artworkId)  $default,) {final _that = this;
switch (_that) {
case _Song():
return $default(_that.id,_that.path,_that.title,_that.artist,_that.album,_that.albumArtist,_that.year,_that.genre,_that.duration,_that.trackNumber,_that.discNumber,_that.fileSize,_that.fileType,_that.sampleRate,_that.bitDepth,_that.artworkId);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String path,  String title,  String artist,  String album, @JsonKey(name: 'albumartist')  String albumArtist,  int year,  String genre,  double duration,  int trackNumber,  int discNumber,  int fileSize,  String fileType,  int? sampleRate,  int? bitDepth, @JsonKey(name: 'artworkId')  String artworkId)?  $default,) {final _that = this;
switch (_that) {
case _Song() when $default != null:
return $default(_that.id,_that.path,_that.title,_that.artist,_that.album,_that.albumArtist,_that.year,_that.genre,_that.duration,_that.trackNumber,_that.discNumber,_that.fileSize,_that.fileType,_that.sampleRate,_that.bitDepth,_that.artworkId);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _Song extends Song {
  const _Song({required this.id, required this.path, this.title = '', this.artist = '', this.album = '', @JsonKey(name: 'albumartist') this.albumArtist = '', this.year = 0, this.genre = '', this.duration = 0.0, this.trackNumber = 0, this.discNumber = 0, this.fileSize = 0, this.fileType = '', this.sampleRate, this.bitDepth, @JsonKey(name: 'artworkId') this.artworkId = ''}): super._();
  factory _Song.fromJson(Map<String, dynamic> json) => _$SongFromJson(json);

@override final  String id;
@override final  String path;
@override@JsonKey() final  String title;
@override@JsonKey() final  String artist;
@override@JsonKey() final  String album;
@override@JsonKey(name: 'albumartist') final  String albumArtist;
@override@JsonKey() final  int year;
@override@JsonKey() final  String genre;
@override@JsonKey() final  double duration;
@override@JsonKey() final  int trackNumber;
@override@JsonKey() final  int discNumber;
@override@JsonKey() final  int fileSize;
@override@JsonKey() final  String fileType;
@override final  int? sampleRate;
@override final  int? bitDepth;
// SHA256 hash of "albumArtist---album" — used to construct artwork URLs.
// Added by the /wear/songs endpoint; null on older server versions.
@override@JsonKey(name: 'artworkId') final  String artworkId;

/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SongCopyWith<_Song> get copyWith => __$SongCopyWithImpl<_Song>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SongToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Song&&(identical(other.id, id) || other.id == id)&&(identical(other.path, path) || other.path == path)&&(identical(other.title, title) || other.title == title)&&(identical(other.artist, artist) || other.artist == artist)&&(identical(other.album, album) || other.album == album)&&(identical(other.albumArtist, albumArtist) || other.albumArtist == albumArtist)&&(identical(other.year, year) || other.year == year)&&(identical(other.genre, genre) || other.genre == genre)&&(identical(other.duration, duration) || other.duration == duration)&&(identical(other.trackNumber, trackNumber) || other.trackNumber == trackNumber)&&(identical(other.discNumber, discNumber) || other.discNumber == discNumber)&&(identical(other.fileSize, fileSize) || other.fileSize == fileSize)&&(identical(other.fileType, fileType) || other.fileType == fileType)&&(identical(other.sampleRate, sampleRate) || other.sampleRate == sampleRate)&&(identical(other.bitDepth, bitDepth) || other.bitDepth == bitDepth)&&(identical(other.artworkId, artworkId) || other.artworkId == artworkId));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,path,title,artist,album,albumArtist,year,genre,duration,trackNumber,discNumber,fileSize,fileType,sampleRate,bitDepth,artworkId);

@override
String toString() {
  return 'Song(id: $id, path: $path, title: $title, artist: $artist, album: $album, albumArtist: $albumArtist, year: $year, genre: $genre, duration: $duration, trackNumber: $trackNumber, discNumber: $discNumber, fileSize: $fileSize, fileType: $fileType, sampleRate: $sampleRate, bitDepth: $bitDepth, artworkId: $artworkId)';
}


}

/// @nodoc
abstract mixin class _$SongCopyWith<$Res> implements $SongCopyWith<$Res> {
  factory _$SongCopyWith(_Song value, $Res Function(_Song) _then) = __$SongCopyWithImpl;
@override @useResult
$Res call({
 String id, String path, String title, String artist, String album,@JsonKey(name: 'albumartist') String albumArtist, int year, String genre, double duration, int trackNumber, int discNumber, int fileSize, String fileType, int? sampleRate, int? bitDepth,@JsonKey(name: 'artworkId') String artworkId
});




}
/// @nodoc
class __$SongCopyWithImpl<$Res>
    implements _$SongCopyWith<$Res> {
  __$SongCopyWithImpl(this._self, this._then);

  final _Song _self;
  final $Res Function(_Song) _then;

/// Create a copy of Song
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? path = null,Object? title = null,Object? artist = null,Object? album = null,Object? albumArtist = null,Object? year = null,Object? genre = null,Object? duration = null,Object? trackNumber = null,Object? discNumber = null,Object? fileSize = null,Object? fileType = null,Object? sampleRate = freezed,Object? bitDepth = freezed,Object? artworkId = null,}) {
  return _then(_Song(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,artist: null == artist ? _self.artist : artist // ignore: cast_nullable_to_non_nullable
as String,album: null == album ? _self.album : album // ignore: cast_nullable_to_non_nullable
as String,albumArtist: null == albumArtist ? _self.albumArtist : albumArtist // ignore: cast_nullable_to_non_nullable
as String,year: null == year ? _self.year : year // ignore: cast_nullable_to_non_nullable
as int,genre: null == genre ? _self.genre : genre // ignore: cast_nullable_to_non_nullable
as String,duration: null == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as double,trackNumber: null == trackNumber ? _self.trackNumber : trackNumber // ignore: cast_nullable_to_non_nullable
as int,discNumber: null == discNumber ? _self.discNumber : discNumber // ignore: cast_nullable_to_non_nullable
as int,fileSize: null == fileSize ? _self.fileSize : fileSize // ignore: cast_nullable_to_non_nullable
as int,fileType: null == fileType ? _self.fileType : fileType // ignore: cast_nullable_to_non_nullable
as String,sampleRate: freezed == sampleRate ? _self.sampleRate : sampleRate // ignore: cast_nullable_to_non_nullable
as int?,bitDepth: freezed == bitDepth ? _self.bitDepth : bitDepth // ignore: cast_nullable_to_non_nullable
as int?,artworkId: null == artworkId ? _self.artworkId : artworkId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
