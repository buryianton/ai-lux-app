// lib/services/measurement_log.dart
//
// CSV measurement logging with multiple named log files.
//
// Files live in the app's external files directory:
//   /sdcard/Android/data/com.buryi.ai_lux_app/files/
// readable over USB file transfer and plain `adb pull` (no run-as needed).
//
// The "active" log receives new rows; its name persists across app
// restarts via a small active_log.txt marker file. Any number of logs
// can be created (per session / room / object / experiment).
//
// Row schema (identical in every log): timestamp, image, source,
// meter_lux, room_id, lamp_type, surface, note, then one column per
// regression model (lux) and two per classifier (label + probability),
// in InferenceService.availableModels order.

import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'inference_service.dart';

class MeasurementLog {
  static const defaultLog = 'measurements_log.csv';
  static const _activeMarker = 'active_log.txt';
  static String _activeLog = defaultLog;

  // ── Files & active-log handling ─────────────────────────────────────

  static Future<Directory> _dir() async =>
      await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();

  static Future<File> _file(String name) async =>
      File('${(await _dir()).path}${Platform.pathSeparator}$name');

  /// Public accessor so screens can share a log file.
  static Future<File> fileOf(String name) => _file(name);

  /// Name of the log that currently receives new measurements.
  static Future<String> activeLog() async {
    final marker = await _file(_activeMarker);
    if (await marker.exists()) {
      final saved = (await marker.readAsString()).trim();
      if (saved.isNotEmpty) _activeLog = saved;
    }
    return _activeLog;
  }

  static Future<void> setActiveLog(String name) async {
    _activeLog = _sanitize(name);
    final marker = await _file(_activeMarker);
    await marker.writeAsString(_activeLog);
  }

  /// All existing measurement CSVs in the log directory.
  static Future<List<String>> listLogs() async {
    final dir = await _dir();
    final names = <String>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.csv')) {
        names.add(e.uri.pathSegments.last);
      }
    }
    names.sort();
    return names;
  }

  /// Creates a new (empty, header-only) log and makes it active.
  static Future<String> createLog(String name) async {
    final clean = _sanitize(name);
    final file = await _file(clean);
    if (!await file.exists()) {
      await file.writeAsString('${_headerCells().join(',')}\n');
    }
    await setActiveLog(clean);
    return clean;
  }

  static String _sanitize(String name) {
    var n = name.trim().replaceAll(RegExp(r'[^\w\-. ]'), '_');
    if (n.isEmpty) n = defaultLog;
    if (!n.toLowerCase().endsWith('.csv')) n = '$n.csv';
    return n;
  }

  // ── Schema ──────────────────────────────────────────────────────────

  static String _q(String s) => '"${s.replaceAll('"', '""')}"';

  static List<String> _headerCells() {
    final cells = <String>[
      'timestamp', 'image', 'source', 'device', 'meter_lux',
      'room_id', 'lamp_type', 'surface', 'note',
    ];
    for (final m in InferenceService.allModels) {
      if (m.name.startsWith('clf')) {
        cells.add('${m.name}_label');
        cells.add('${m.name}_prob');
      } else if (m.name.startsWith('et_multi')) {
        for (final p in ['C', 'UL', 'UR', 'LR', 'LL']) {
          cells.add('${m.name}_${p}_lux');
        }
        cells.add('${m.name}_C_cal_lux');
      } else {
        cells.add('${m.name}_lux');
        cells.add('${m.name}_cal_lux'); // calibrated (empty if no fit)
      }
    }
    return cells;
  }

  // ── Append ──────────────────────────────────────────────────────────

  /// Appends one measurement row to the ACTIVE log; creates it with a
  /// header if new. Returns the log file so the UI can show its path.
  static Future<File> append({
    required String imageName,
    required String source, // 'capture' | 'upload'
    required Map<String, InferenceResult> results,
    Map<String, double> calibrated = const {}, // model -> calibrated lux
    double? meterLux,
    String roomId = '',
    String lampType = '',
    String surface = '',
    String note = '',
  }) async {
    final file = await _file(await activeLog());

    // Build column -> value for the CURRENT schema
    final vals = <String, String>{
      'timestamp': DateTime.now().toIso8601String(),
      'image': _q(imageName),
      'source': source,
      'device': _q(InferenceService.deviceModel),
      'meter_lux': meterLux != null ? meterLux.toStringAsFixed(1) : '',
      'room_id': _q(roomId),
      'lamp_type': _q(lampType),
      'surface': _q(surface),
      'note': _q(note),
    };
    for (final m in InferenceService.allModels) {
      final r = results[m.name];
      final cal = calibrated[m.name];
      if (m.name.startsWith('clf')) {
        vals['${m.name}_label'] = r?.classLabel?.toString() ?? '';
        vals['${m.name}_prob'] =
            r?.classProbability?.toStringAsFixed(4) ?? '';
      } else if (m.name.startsWith('et_multi')) {
        for (final p in ['C', 'UL', 'UR', 'LR', 'LL']) {
          vals['${m.name}_${p}_lux'] =
              r?.luxByPoint?[p]?.toStringAsFixed(1) ?? '';
        }
        vals['${m.name}_C_cal_lux'] = cal?.toStringAsFixed(1) ?? '';
      } else {
        vals['${m.name}_lux'] = r?.luxEstimate?.toStringAsFixed(1) ?? '';
        vals['${m.name}_cal_lux'] = cal?.toStringAsFixed(1) ?? '';
      }
    }

    // Emit the row in the FILE's own header order so older logs with a
    // previous schema stay perfectly aligned.
    List<String> header;
    if (!await file.exists()) {
      header = _headerCells();
      await file.writeAsString('${header.join(',')}\n');
    } else {
      final lines = await file.readAsLines();
      header = lines.isNotEmpty && lines.first.trim().isNotEmpty
          ? _parseCsvLine(lines.first)
          : _headerCells();
    }
    final row = [for (final h in header) vals[h] ?? ''].join(',');
    await file.writeAsString('$row\n', mode: FileMode.append, flush: true);
    return file;
  }

  // ── Read & delete ───────────────────────────────────────────────────

  /// Parses a log into (header, dataRows). Rows are lists of cell strings.
  static Future<(List<String>, List<List<String>>)> readLog(
      String name) async {
    final file = await _file(name);
    if (!await file.exists()) return (<String>[], <List<String>>[]);
    final lines = (await file.readAsLines())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return (<String>[], <List<String>>[]);
    final header = _parseCsvLine(lines.first);
    final rows = [for (final l in lines.skip(1)) _parseCsvLine(l)];
    return (header, rows);
  }

  /// Deletes data row [rowIndex] (0-based, header excluded) from [name].
  static Future<void> deleteRow(String name, int rowIndex) async {
    final file = await _file(name);
    if (!await file.exists()) return;
    final lines = (await file.readAsLines())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final lineIdx = rowIndex + 1; // +1 for header
    if (lineIdx <= 0 || lineIdx >= lines.length) return;
    lines.removeAt(lineIdx);
    await file.writeAsString('${lines.join('\n')}\n', flush: true);
  }

  /// Minimal CSV line parser handling our own quoting style.
  static List<String> _parseCsvLine(String line) {
    final cells = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buf.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buf.write(ch);
        }
      } else {
        if (ch == '"') {
          inQuotes = true;
        } else if (ch == ',') {
          cells.add(buf.toString());
          buf.clear();
        } else {
          buf.write(ch);
        }
      }
    }
    cells.add(buf.toString());
    return cells;
  }
}
