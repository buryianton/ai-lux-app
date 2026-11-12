// lib/screens/photos_screen.dart
//
// Browser for photos saved by the app:
//   - dataset_photos/  (clean captures saved for the dataset)
//   - report_photos/   (annotated evidence snapshots)
// Grid of thumbnails, newest first; tap to view full screen (pinch to
// zoom) with the filename and a share/export button. No delete — saved
// data is protected; manage files over USB/adb if ever needed.

import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/photo_saver.dart';

const _green = Color(0xFF1D9E75);

class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key});

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  bool _reports = false; // false = dataset photos, true = report photos
  List<File> _files = [];
  bool _loading = true;
  bool _zipping = false;

  /// Zips the whole current folder (photos + sidecar CSV) and opens the
  /// system share sheet — the one-tap way for volunteers to send a whole
  /// collection session (share to Drive/email; large sets need Drive).
  Future<void> _exportZip() async {
    if (_files.isEmpty || _zipping) return;
    setState(() => _zipping = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Preparing ZIP — this can take a minute for a '
            'large session...')));
    try {
      final srcDir =
          _reports ? await PhotoSaver.reportDir() : await PhotoSaver.dir();
      final tmp = await getTemporaryDirectory();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final zipPath = '${tmp.path}${Platform.pathSeparator}'
          'ai_lux_${_reports ? "reports" : "dataset"}_'
          '${now.year}${two(now.month)}${two(now.day)}.zip';
      final old = File(zipPath);
      if (await old.exists()) await old.delete();
      final enc = ZipFileEncoder();
      enc.create(zipPath);
      await for (final e in srcDir.list()) {
        if (e is File) await enc.addFile(e);
      }
      await enc.close();
      if (!mounted) return;
      final sizeMb =
          (await File(zipPath).length()) / (1024 * 1024);
      await Share.shareXFiles([XFile(zipPath)],
          text: 'AI Lux ${_reports ? "report" : "dataset"} photos '
              '(${_files.length} files, ${sizeMb.toStringAsFixed(0)} MB)');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: Colors.red,
          content: Text('Export failed: $e')));
    } finally {
      if (mounted) setState(() => _zipping = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final dir =
        _reports ? await PhotoSaver.reportDir() : await PhotoSaver.dir();
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File) {
        final n = e.path.toLowerCase();
        if (n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png')) {
          files.add(e);
        }
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path)); // timestamped names
    if (mounted) {
      setState(() {
        _files = files;
        _loading = false;
      });
    }
  }

  void _open(File f) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _PhotoViewer(file: f)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Saved photos', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: _zipping
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white70, strokeWidth: 2))
                : const Icon(Icons.archive_outlined),
            tooltip: 'Export all as ZIP',
            onPressed: _zipping ? null : _exportZip,
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            _chip('Dataset photos', !_reports, () {
              if (_reports) {
                setState(() => _reports = false);
                _load();
              }
            }),
            const SizedBox(width: 8),
            _chip('Report photos', _reports, () {
              if (!_reports) {
                setState(() => _reports = true);
                _load();
              }
            }),
            const Spacer(),
            Text('${_files.length}',
                style:
                    const TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: _green))
              : _files.isEmpty
                  ? Center(
                      child: Text(
                        _reports
                            ? 'No report photos yet.\nUse "Save report '
                                'photo" on a results screen.'
                            : 'No dataset photos yet.\nUse "Save photo '
                                'for dataset" on a results screen.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 3 / 4,
                      ),
                      itemCount: _files.length,
                      itemBuilder: (_, i) => GestureDetector(
                        onTap: () => _open(_files[i]),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            _files[i],
                            fit: BoxFit.cover,
                            cacheWidth: 300,
                          ),
                        ),
                      ),
                    ),
        ),
      ]),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _green.withValues(alpha: 0.15) : Colors.black,
          borderRadius: BorderRadius.circular(16),
          border:
              Border.all(color: selected ? _green : Colors.white24),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? _green : Colors.white54,
                fontSize: 12,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  final File file;
  const _PhotoViewer({required this.file});

  @override
  Widget build(BuildContext context) {
    final name = file.uri.pathSegments.last;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name,
            style: const TextStyle(fontSize: 11),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share / export',
            onPressed: () => Share.shareXFiles([XFile(file.path)]),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 8,
          child: Image.file(file),
        ),
      ),
    );
  }
}
