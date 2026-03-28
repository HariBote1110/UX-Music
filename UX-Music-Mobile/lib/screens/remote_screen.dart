import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/library_provider.dart';

class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});

  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  Timer? _pollTimer;
  Map<String, dynamic>? _state;
  String? _error;

  @override
  void initState() {
    super.initState();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final client = ref.read(apiClientProvider);
      final state = await client.fetchState();
      if (mounted) setState(() { _state = state; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _send(String action, {double? value}) async {
    try {
      final client = ref.read(apiClientProvider);
      await client.sendCommand(action, value: value);
      await _poll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Command failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Remote Control')),
      body: _error != null && _state == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  Text('Desktop unreachable',
                      style: TextStyle(color: Colors.grey[400])),
                ],
              ),
            )
          : _buildControls(),
    );
  }

  Widget _buildControls() {
    final playing = _state?['playing'] == true;
    final position = (_state?['position'] as num?)?.toDouble() ?? 0;
    final duration = (_state?['duration'] as num?)?.toDouble() ?? 0;
    final title = _state?['title'] as String? ?? '';
    final artist = _state?['artist'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(),
          // Connection indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.circle,
                size: 8,
                color: _error == null ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Text(
                _error == null ? 'Connected' : 'Reconnecting…',
                style: TextStyle(color: Colors.grey[400], fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 32),
          // Track info
          Icon(Icons.desktop_mac, size: 48, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            title.isEmpty ? 'No track' : title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            artist,
            style: TextStyle(fontSize: 16, color: Colors.grey[400]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          // Seek bar
          if (duration > 0) ...[
            Slider(
              value: position.clamp(0, duration),
              max: duration,
              onChanged: (v) => _send('seek', value: v),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(position),
                      style: TextStyle(fontSize: 12, color: Colors.grey[400])),
                  Text(_fmt(duration),
                      style: TextStyle(fontSize: 12, color: Colors.grey[400])),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 36,
                icon: const Icon(Icons.skip_previous),
                onPressed: () => _send('prev'),
              ),
              const SizedBox(width: 24),
              IconButton(
                iconSize: 64,
                icon: Icon(playing
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled),
                onPressed: () => _send('toggle'),
              ),
              const SizedBox(width: 24),
              IconButton(
                iconSize: 36,
                icon: const Icon(Icons.skip_next),
                onPressed: () => _send('next'),
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }

  String _fmt(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).truncate();
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
