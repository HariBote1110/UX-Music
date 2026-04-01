import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_service.dart';

final musicPlayerProvider = Provider<MusicPlayerService>((ref) {
  final service = MusicPlayerService();
  ref.onDispose(() => service.dispose());
  return service;
});
