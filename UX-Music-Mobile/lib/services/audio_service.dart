import 'dart:math';

import 'package:just_audio/just_audio.dart';

import '../core/constants.dart';
import '../models/song.dart';

/// Wraps [AudioPlayer] for local music playback with loudness normalisation.
class MusicPlayerService {
  MusicPlayerService() : _player = AudioPlayer();

  final AudioPlayer _player;

  // Current queue and position
  final List<Song> _queue = [];
  int _currentIndex = -1;

  // Loudness normalisation
  Map<String, double> _loudnessMap = {};
  double _targetLoudness = kDefaultTargetLoudness;
  bool _normaliseEnabled = true;
  double _masterVolume = 1.0;

  // Public getters
  AudioPlayer get player => _player;
  Song? get currentSong =>
      _currentIndex >= 0 && _currentIndex < _queue.length
          ? _queue[_currentIndex]
          : null;
  List<Song> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;

  Stream<Duration?> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  void updateLoudnessMap(Map<String, double> map) {
    _loudnessMap = map;
  }

  void setTargetLoudness(double lufs) {
    _targetLoudness = lufs;
    _applyLoudnessGain();
  }

  void setNormaliseEnabled(bool enabled) {
    _normaliseEnabled = enabled;
    _applyLoudnessGain();
  }

  void setMasterVolume(double volume) {
    _masterVolume = volume.clamp(0.0, 1.0);
    _applyLoudnessGain();
  }

  /// Play a song, optionally setting a new queue.
  Future<void> play(Song song, {List<Song>? newQueue}) async {
    if (newQueue != null) {
      _queue
        ..clear()
        ..addAll(newQueue);
    }
    _currentIndex = _queue.indexWhere((s) => s.id == song.id);
    if (_currentIndex == -1) {
      _queue.add(song);
      _currentIndex = _queue.length - 1;
    }
    await _loadAndPlay(song);
  }

  Future<void> togglePlayPause() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    _currentIndex = (_currentIndex + 1) % _queue.length;
    await _loadAndPlay(_queue[_currentIndex]);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;
    // If more than 3 seconds in, restart; otherwise go to previous
    if ((_player.position.inSeconds) > 3) {
      await _player.seek(Duration.zero);
    } else {
      _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
      await _loadAndPlay(_queue[_currentIndex]);
    }
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> dispose() async {
    await _player.dispose();
  }

  // ─── Private ────────────────────────────────────────────────────────

  Future<void> _loadAndPlay(Song song) async {
    await _player.setFilePath(song.path);
    _applyLoudnessGain();
    await _player.play();
  }

  void _applyLoudnessGain() {
    if (!_normaliseEnabled || currentSong == null) {
      _player.setVolume(_masterVolume);
      return;
    }
    final lufs = _loudnessMap[currentSong!.id];
    if (lufs == null) {
      _player.setVolume(_masterVolume);
      return;
    }
    final gainDb = _targetLoudness - lufs;
    final linearGain = pow(10.0, gainDb / 20.0).toDouble();
    // Clamp to avoid distortion; allow up to +12 dB boost (4x)
    final clamped = linearGain.clamp(0.0, 4.0);
    _player.setVolume(_masterVolume * clamped);
  }
}
