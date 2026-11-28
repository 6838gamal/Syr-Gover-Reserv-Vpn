import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/vpn_controller.dart';  // ← بدل ../main.dart
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
  bool _busy = false;

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await FilePicker.platform
          .pickFiles(withData: true)
          .timeout(const Duration(seconds: 30), onTimeout: () => null);

      if (res == null) return;

      final f = res.files.single;
      if (f.bytes == null) {
        setState(() => _error = 'تعذّر قراءة الملف');
        return;
      }

      final content = utf8.decode(f.bytes!, allowMalformed: true);
      if (!mounted) return;

      setState(() {
        _confCtrl.text = content;
        _error = null;
      });

      if (_nameCtrl.text.isEmpty && f.name.contains('.')) {
        _nameCtrl.text = f.name.split('.').first;
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'فشل اختيار الملف: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cfg = VpnConfig.fromConf(
        _confCtrl.text,
        name: _nameCtrl.text.trim().isEmpty
            ? 'imported'
            : _nameCtrl.text.trim(),
      );

      final ctrl = context.read<VpnController>();

      // اسأل قبل الاستبدال
      final exists = await ctrl.store.exists(cfg.name);
      if (exists && mounted) {
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('استبدال الإعدادات؟'),
            content: Text(
              'يوجد إعدادات باسم "${cfg.name}" مسبقاً.\n'
              'هل تريد استبدالها؟',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('استبدال'),
              ),
            ],
          ),
        );
        if (overwrite != true) return;
      }

      await ctrl.store.add(cfg);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
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
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'اسم الإعدادات',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confCtrl,
              maxLines: 12,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'محتوى .conf',
                hintText:
                    '[Interface]\nPrivateKey = ...\nAddress = ...\n\n'
                    '[Peer]\nPublicKey = ...\nEndpoint = ...\nAllowedIPs = ...',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pick,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_open),
              label: const Text('اختيار ملف .conf'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
  }
}
