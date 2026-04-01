import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/library_provider.dart';
import '../providers/settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _hostController;
  late TextEditingController _portController;
  final FocusNode _hostFocus = FocusNode();
  final FocusNode _portFocus = FocusNode();
  String? _pingResult;
  bool _testing = false;
  bool _saved = false;
  Timer? _savedTimer;

  @override
  void initState() {
    super.initState();
    final config = ref.read(settingsProvider);
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _hostFocus.dispose();
    _portFocus.dispose();
    _savedTimer?.cancel();
    super.dispose();
  }

  void _dismissKeyboard() {
    _hostFocus.unfocus();
    _portFocus.unfocus();
  }

  Future<void> _save() async {
    _dismissKeyboard();
    await ref.read(settingsProvider.notifier).update(
          host: _hostController.text.trim(),
          port: int.tryParse(_portController.text) ?? 8765,
        );
    if (mounted) {
      setState(() => _saved = true);
      _savedTimer?.cancel();
      _savedTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _saved = false);
      });
    }
  }

  Future<void> _testConnection() async {
    _dismissKeyboard();
    setState(() {
      _testing = true;
      _pingResult = null;
    });
    try {
      final client = ref.read(apiClientProvider);
      final hostname = await client.ping();
      if (mounted) setState(() => _pingResult = 'Connected to $hostname');
    } catch (e) {
      if (mounted) setState(() => _pingResult = 'Connection failed: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Tap outside fields to dismiss keyboard
      onTap: _dismissKeyboard,
      behavior: HitTestBehavior.translucent,
      child: CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(transitionBetweenRoutes: false,
          middle: Text('Settings'),
          // Fully opaque — prevents content bleeding through when scrolled up
          backgroundColor: Color(0xFF1C1C1E),
        ),
        child: ListView(
          // CupertinoPageScaffold already offsets by statusBar + navBar height.
          // The explicit top padding here is just aesthetic spacing below that.
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          physics: const BouncingScrollPhysics(),
          children: [
            // ── Server section ──
            const Text(
              'SERVER',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.systemGrey,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            // Host field
            CupertinoTextField(
              controller: _hostController,
              focusNode: _hostFocus,
              placeholder: '192.168.1.100',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 12),
                child: Text(
                  'Host',
                  style: TextStyle(color: CupertinoColors.systemGrey),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _portFocus.requestFocus(),
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 8),
            // Port field — use phone keypad with Done button
            CupertinoTextField(
              controller: _portController,
              focusNode: _portFocus,
              placeholder: '8765',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 12),
                child: Text(
                  'Port',
                  style: TextStyle(color: CupertinoColors.systemGrey),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              // numberWithOptions prevents the iOS number pad that has no Done button
              keyboardType:
                  const TextInputType.numberWithOptions(signed: false, decimal: false),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _dismissKeyboard(),
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 16),
            // Buttons row
            Row(
              children: [
                Expanded(
                  child: CupertinoButton.filled(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    borderRadius: BorderRadius.circular(10),
                    onPressed: _save,
                    child: Text(_saved ? 'Saved ✓' : 'Save'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    borderRadius: BorderRadius.circular(10),
                    color: const Color(0xFF3A3A3C),
                    onPressed: _testing ? null : _testConnection,
                    child: _testing
                        ? const CupertinoActivityIndicator()
                        : const Text('Test'),
                  ),
                ),
              ],
            ),
            // Ping result
            if (_pingResult != null) ...[
              const SizedBox(height: 12),
              Text(
                _pingResult!,
                style: TextStyle(
                  fontSize: 13,
                  color: _pingResult!.startsWith('Connected')
                      ? CupertinoColors.systemGreen
                      : CupertinoColors.systemRed,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
