// lib/services/photo_saver.dart
//
// Saves an analyzed photo into a dataset_photos/ folder with a
// dataset-compatible filename encoding lux values and context:
//
//   {device}_{yyyyMMdd-HHmmss}__LC{c}_UL{ul}_UR{ur}_LR{lr}_LL{ll}
//       __S{surface}__L{lamp}__{settings}.jpg
//
// Token rules (mirrors the published dataset convention):
//   - the whole LC... block is omitted when no meter value was entered
//     (an unlabeled photo is visibly unlabeled);
//   - corner tokens appear only for corners that were measured;
//   - S/L tokens are lowercase slugs; omitted when empty;
//   - settings token is ISO50-20ms for native captures, 'upload' otherwise.
//
// The JPEG is copied byte-for-byte (no recompression). A sidecar CSV in
// the same folder (dataset_photos_log.csv) is the authoritative record;
// filename encoding is duplication-by-design, like the dataset itself.
//
// Folder: /sdcard/Android/data/com.buryi.ai_lux_app/files/dataset_photos/

import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'inference_service.dart';

class PhotoSaver {
  static const folder = 'dataset_photos';
  static const sidecarName = 'dataset_photos_log.csv';

  /// Annotated evidence photos (ROI overlay + values burned in). Kept in
  /// a SEPARATE folder with a __REPORT name token so annotated pixels can
  /// never be mistaken for training data.
  static const reportFolder = 'report_photos';

  static Future<Directory> dir() async {
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}$folder');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<Directory> reportDir() async {
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final d =
        Directory('${base.path}${Platform.pathSeparator}$reportFolder');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Saves an annotated report snapshot (PNG bytes from the results
  /// screen) into report_photos/ with a __REPORT name token.
  static Future<File> saveReportPng(List<int> pngBytes,
      {double? luxC}) async {
    final d = await reportDir();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final dev = _slug(InferenceService.deviceModel.isEmpty
        ? 'unknown_device'
        : InferenceService.deviceModel);
    final lux = luxC != null ? '__LC${_lux(luxC)}' : '';
    final f = File('${d.path}${Platform.pathSeparator}'
        '${dev}_$ts$lux'
        '__REPORT.png');
    await f.writeAsBytes(pngBytes, flush: true);
    return f;
  }

  static String _slug(String s) {
    var t = s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    t = t.replaceAll(RegExp(r'_+'), '_');
    t = t.replaceAll(RegExp(r'^_+|_+$'), '');
    return t;
  }

  static String _q(String s) => '"${s.replaceAll('"', '""')}"';

  static String _lux(double v) => v.round().toString();

  /// One-time repair for photos saved by the File.copy version: they got
  /// 0600 permissions, unreadable over adb. Rewriting each file through a
  /// byte write makes it group-readable. Safe to call repeatedly - files
  /// that already have group read are skipped.
  static Future<int> makeShareable() async {
    final d = await dir();
    var fixed = 0;
    await for (final e in d.list()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.jpg')) continue;
      final mode = (await e.stat()).modeString();
      if (mode.length >= 4 && mode[3] == 'r') continue; // group-readable
      final bytes = await e.readAsBytes();
      final tmp = File('${e.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await e.delete();
      await tmp.rename(e.path);
      fixed++;
    }
    return fixed;
  }

  /// Copies [imagePath] into dataset_photos/ under the dataset-style name
  /// and appends one sidecar CSV row. Returns the saved file.
  static Future<File> save({
    required String imagePath,
    required String source, // 'capture' | 'upload'
    double? luxC,
    double? luxUL,
    double? luxUR,
    double? luxLR,
    double? luxLL,
    String surface = '',
    String lampType = '',
    String note = '',
    double? heightCm, // camera height from the height chip
    String? position, // flat-field frame position (nw/n/ne/w/c/e/sw/s/se)
    double? angleDeg, // measured tilt when angle-free mode was on
    String extraTag = '', // free token, e.g. FP123456t0/t1 for flash pairs
  }) async {
    final d = await dir();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final devRaw = InferenceService.deviceModel;
    final dev = _slug(devRaw.isEmpty ? 'unknown_device' : devRaw);

    var luxBlock = '';
    if (luxC != null) {
      luxBlock = '__LC${_lux(luxC)}';
      if (luxUL != null) luxBlock += '_UL${_lux(luxUL)}';
      if (luxUR != null) luxBlock += '_UR${_lux(luxUR)}';
      if (luxLR != null) luxBlock += '_LR${_lux(luxLR)}';
      if (luxLL != null) luxBlock += '_LL${_lux(luxLL)}';
    }
    final sTok = surface.trim().isEmpty ? '' : '__S${_slug(surface)}';
    final lTok = lampType.trim().isEmpty ? '' : '__L${_slug(lampType)}';
    final hTok = heightCm == null ? '' : '__H${heightCm.round()}cm';
    final pTok = position == null || position.isEmpty
        ? ''
        : '__POS${_slug(position)}';
    final aTok = angleDeg == null ? '' : '__A${angleDeg.round()}deg';
    final xTok = extraTag.trim().isEmpty ? '' : '__${_slug(extraTag)}';
    final settings = source == 'capture' ? 'ISO50-20ms' : 'upload';

    var name = '${dev}_$ts$luxBlock$sTok$lTok$hTok$pTok$aTok$xTok'
        '__$settings.jpg';
    // Collision guard (two saves within one second).
    var target = File('${d.path}${Platform.pathSeparator}$name');
    var i = 2;
    while (await target.exists()) {
      name = name.replaceFirst('.jpg', '_$i.jpg');
      target = File('${d.path}${Platform.pathSeparator}$name');
      i++;
    }

    // Byte write (not File.copy): copy() creates owner-only (0600) files in
    // the external files dir, which blocks `adb pull`; a plain write yields
    // group-readable files like the sidecar CSV.
    await target.writeAsBytes(await File(imagePath).readAsBytes(),
        flush: true);

    // Sidecar CSV — the authoritative record.
    final sidecar = File('${d.path}${Platform.pathSeparator}$sidecarName');
    const header = 'saved_name,original_image,timestamp,device,source,'
        'lux_C,lux_UL,lux_UR,lux_LR,lux_LL,surface,lamp_type,note';
    if (!await sidecar.exists()) {
      await sidecar.writeAsString('$header\n');
    }
    String f(double? v) => v?.toStringAsFixed(1) ?? '';
    final row = [
      _q(name),
      _q(imagePath.split(Platform.pathSeparator).last),
      now.toIso8601String(),
      _q(devRaw),
      source,
      f(luxC), f(luxUL), f(luxUR), f(luxLR), f(luxLL),
      _q(surface.trim()),
      _q(lampType.trim()),
      _q(note.trim()),
    ].join(',');
    await sidecar.writeAsString('$row\n',
        mode: FileMode.append, flush: true);

    return target;
  }
}
