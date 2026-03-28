import 'package:flutter/material.dart';
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
  String? _pingResult;
  bool _testing = false;

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
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(settingsProvider.notifier).update(
          host: _hostController.text.trim(),
          port: int.tryParse(_portController.text) ?? 8765,
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _pingResult = null;
    });
    try {
      final client = ref.read(apiClientProvider);
      final hostname = await client.ping();
      setState(() => _pingResult = 'Connected to $hostname');
    } catch (e) {
      setState(() => _pingResult = 'Connection failed: $e');
    } finally {
      setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Server',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(
              labelText: 'Host (IP address)',
              hintText: '192.168.1.100',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _portController,
            decoration: const InputDecoration(
              labelText: 'Port',
              hintText: '8765',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _testConnection,
                  child: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Test Connection'),
                ),
              ),
            ],
          ),
          if (_pingResult != null) ...[
            const SizedBox(height: 12),
            Text(
              _pingResult!,
              style: TextStyle(
                color: _pingResult!.startsWith('Connected')
                    ? Colors.green
                    : Colors.red,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
