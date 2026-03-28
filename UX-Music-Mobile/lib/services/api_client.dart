import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';

/// HTTP client for the UX Music Wear LAN API (port 8765).
class ApiClient {
  ApiClient(String baseUrl)
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 30),
        ));

  final Dio _dio;

  void updateBaseUrl(String baseUrl) {
    _dio.options.baseUrl = baseUrl;
  }

  /// Health check. Returns the server hostname on success.
  Future<String> ping() async {
    final res = await _dio.get('/wear/ping');
    return res.data['hostname'] as String? ?? '';
  }

  /// Fetch the full song library (artwork stripped).
  Future<List<Song>> fetchSongs() async {
    final res = await _dio.get('/wear/songs');
    final list = res.data as List;
    return list.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Fetch the loudness map: songID → LUFS value.
  Future<Map<String, double>> fetchLoudness() async {
    final res = await _dio.get('/wear/loudness');
    final map = res.data as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, (v as num).toDouble()));
  }

  /// Fetch the current desktop playback state.
  Future<Map<String, dynamic>> fetchState() async {
    final res = await _dio.get('/wear/state');
    return res.data as Map<String, dynamic>;
  }

  /// Send a remote playback command.
  Future<bool> sendCommand(String action, {double? value}) async {
    final body = <String, dynamic>{'action': action};
    if (value != null) body['value'] = value;
    final res = await _dio.post('/wear/command', data: body);
    return res.data['ok'] == true;
  }

  /// Build the artwork URL for a given song ID.
  String artworkUrl(String songId) =>
      '${_dio.options.baseUrl}/wear/artwork/$songId';

  /// Download a song file to the app's documents directory.
  /// Returns the local file path. Reports progress via [onProgress].
  Future<String> downloadFile(
    String songId, {
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}/$songId.m4a';

    await _dio.download(
      '/wear/file/$songId',
      savePath,
      onReceiveProgress: onProgress,
    );

    return savePath;
  }

  /// Check whether a song file already exists locally.
  Future<bool> isDownloaded(String songId) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$songId.m4a').existsSync();
  }
}
