import 'dart:async';

import 'package:flutter/cupertino.dart';
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
      if (mounted) {
        setState(() {
          _state = state;
          _error = null;
        });
      }
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
      if (mounted) setState(() => _error = 'Command failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(transitionBetweenRoutes: false,
        middle: Text('Remote Control'),
        backgroundColor: Color(0xFF1C1C1E),
      ),
      child: _error != null && _state == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.wifi_slash,
                    size: 52,
                    color: CupertinoColors.systemGrey,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Desktop unreachable',
                    style: TextStyle(color: CupertinoColors.systemGrey),
                  ),
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

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          children: [
            const Spacer(),
            // Connection status dot
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _error == null
                        ? CupertinoColors.systemGreen
                        : CupertinoColors.systemOrange,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _error == null ? 'Connected' : 'Reconnecting…',
                  style: const TextStyle(
                    color: CupertinoColors.systemGrey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            // Desktop icon
            const Icon(
              Icons.desktop_mac,
              size: 52,
              color: CupertinoColors.systemGrey2,
            ),
            const SizedBox(height: 16),
            // Track info
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
              style: const TextStyle(
                fontSize: 16,
                color: CupertinoColors.systemGrey,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // Seek bar
            if (duration > 0) ...[
              CupertinoSlider(
                value: position.clamp(0, duration),
                max: duration,
                onChanged: (v) => _send('seek', value: v),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _fmt(position),
                      style: const TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                    Text(
                      _fmt(duration),
                      style: const TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Playback controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  child: const Icon(CupertinoIcons.backward_end_fill, size: 38),
                  onPressed: () => _send('prev'),
                ),
                const SizedBox(width: 24),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  child: Icon(
                    playing
                        ? CupertinoIcons.pause_circle_fill
                        : CupertinoIcons.play_circle_fill,
                    size: 72,
                  ),
                  onPressed: () => _send('toggle'),
                ),
                const SizedBox(width: 24),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  child: const Icon(CupertinoIcons.forward_end_fill, size: 38),
                  onPressed: () => _send('next'),
                ),
              ],
            ),
            // Error message (non-fatal)
            if (_error != null && _state != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: CupertinoColors.systemRed,
                    fontSize: 12,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  String _fmt(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).truncate();
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
