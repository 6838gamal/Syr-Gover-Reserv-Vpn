import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models/vpn_config.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _nameCtrl = TextEditingController();
  final _confCtrl = TextEditingController();
  String? _error;

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(withData: true);
    if (res == null) return;
    final f = res.files.single;
    if (f.bytes == null) {
      setState(() => _error = 'تعذّر قراءة الملف');
      return;
    }
    final content = utf8.decode(f.bytes!);
    setState(() {
      _confCtrl.text = content;
      _error = null;
    });
    if (_nameCtrl.text.isEmpty && f.name.contains('.')) {
      _nameCtrl.text = f.name.split('.').first;
    }
  }

  Future<void> _save() async {
    try {
      final cfg = VpnConfig.fromConf(
        _confCtrl.text,
        name: _nameCtrl.text.trim().isEmpty
            ? 'imported'
            : _nameCtrl.text.trim(),
      );
      await context.read<VpnController>().store.add(cfg);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _confCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('استيراد إعدادات')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'اسم الإعدادات',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confCtrl,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'محتوى .conf',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.file_open),
              label: const Text('اختيار ملف .conf'),
            ),
            const Spacer(),
            FilledButton(onPressed: _save, child: const Text('حفظ')),
          ],
        ),
      ),
    );
  }
}
