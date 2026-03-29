import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

/// Manages downloaded songs: tracks metadata and provides local file paths.
class DownloadManager {
  static const _metaKey = 'downloaded_songs_meta';

  final Map<String, Song> _downloaded = {};
  String _docsPath = '';

  Map<String, Song> get downloadedSongs => Map.unmodifiable(_downloaded);

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _docsPath = dir.path;
    await _loadMeta();
  }

  String localPath(String songId) => '$_docsPath/$songId.m4a';

  bool isDownloaded(String songId) {
    if (!_downloaded.containsKey(songId)) return false;
    return File(localPath(songId)).existsSync();
  }

  Future<void> register(Song song) async {
    _downloaded[song.id] = song;
    await _saveMeta();
  }

  Future<void> remove(String songId) async {
    _downloaded.remove(songId);
    final file = File(localPath(songId));
    if (file.existsSync()) file.deleteSync();
    await _saveMeta();
  }

  Future<void> _loadMeta() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_metaKey);
    if (raw == null) return;
    final list = jsonDecode(raw) as List;
    for (final item in list) {
      final song = Song.fromJson(item as Map<String, dynamic>);
      if (File(localPath(song.id)).existsSync()) {
        _downloaded[song.id] = song;
      }
    }
  }

  Future<void> _saveMeta() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _downloaded.values.map((s) => s.toJson()).toList();
    await prefs.setString(_metaKey, jsonEncode(list));
  }
}
