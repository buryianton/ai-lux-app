// lib/screens/log_viewer_screen.dart
//
// Browse measurement logs on the phone:
//   - dropdown to switch between CSV log files (the selection becomes the
//     ACTIVE log that receives new measurements)
//   - "+" to create a new named log (per session / room / object)
//   - list of rows showing time, image, meter lux, room, lamp
//   - tap a row to see every logged value; trash icon deletes a row
//     after confirmation

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/measurement_log.dart';

const _green = Color(0xFF1D9E75);

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  List<String> _logs = [];
  String _selected = MeasurementLog.defaultLog;
  List<String> _header = [];
  List<List<String>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final active = await MeasurementLog.activeLog();
    var logs = await MeasurementLog.listLogs();
    if (logs.isEmpty) logs = [active];
    if (!logs.contains(active)) logs.insert(0, active);
    final (header, rows) = await MeasurementLog.readLog(active);
    if (!mounted) return;
    setState(() {
      _logs = logs;
      _selected = active;
      _header = header;
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _switchLog(String name) async {
    await MeasurementLog.setActiveLog(name);
    await _refresh();
  }

  Future<void> _shareLog() async {
    final file = await MeasurementLog.fileOf(_selected);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This log has no data yet')));
      return;
    }
    // Companion instructions file: lets anyone drop BOTH files into any
    // AI chat assistant and get an analysis without knowing the schema.
    final prompt = File(
        '${file.parent.path}${Platform.pathSeparator}AI_analysis_instructions.txt');
    await prompt.writeAsString(_aiPromptText(_selected));
    await Share.shareXFiles([XFile(file.path), XFile(prompt.path)],
        subject: 'AI Lux measurements: $_selected',
        text: 'AI Lux measurement log + analysis instructions. '
            'Upload both files to an AI assistant (Claude, ChatGPT, ...) '
            'to get a formatted report.');
  }

  String _aiPromptText(String logName) => '''
INSTRUCTIONS FOR AI ASSISTANT — AI Lux measurement analysis
============================================================
You are given a CSV file ($logName) of workplace illuminance
measurements made with the AI Lux research app (smartphone photos of a
white paper sheet, analyzed by ML models trained on the open dataset
https://doi.org/10.5281/zenodo.20657011). Please analyze it and reply
in the same language the user writes to you.

SCHEMA
- timestamp, image, source: measurement time, photo file, and capture
  path ("capture" = in-app camera with locked settings, "upload" =
  photo imported from gallery). Analyze the two sources SEPARATELY —
  they have different accuracy characteristics.
- device: the phone that made the measurement (e.g. "samsung
  SM-A166U1"). If several devices appear, also analyze per device.
- meter_lux: reference lux meter reading (ground truth). May be empty.
- room_id, lamp_type, surface, note: measurement context.
- Columns ending in _lux: RAW lux predicted by one ML model.
- Columns ending in _cal_lux: the SAME prediction after per-device
  calibration. THIS IS THE PRIMARY VALUE — always prefer _cal_lux over
  the raw column when it is non-empty. Empty _cal_lux means no
  calibration was active for that model when the row was saved.
  The main model pair is et_s8_white_paper_lux /
  et_s8_white_paper_cal_lux.
- IMPORTANT: large RAW errors on the "capture" source (20-90% vs
  meter) are EXPECTED and are corrected by calibration — judge the
  instrument by the _cal_lux columns, not the raw ones. Report both,
  clearly labeled, so the calibration effect is visible.
- Columns like et_multi5_white_paper_C/UL/UR/LR/LL_lux are one model
  predicting the center and four corners of the measured area.
- Columns ending in _label / _prob: threshold classifiers. label=1
  means illuminance is ABOVE the threshold in the model name (250 or
  500 lux); prob is the confidence for "above". Classifiers CANNOT be
  calibrated: on the "capture" source prefer compliance verdicts
  derived from calibrated lux (_cal_lux >= threshold) over classifier
  labels; on "upload" the classifier labels are reliable.

TASKS
1. A clean measurement table: time, room, lamp, device, source,
   meter_lux (if present), calibrated lux (fallback: raw, labeled as
   raw), and 250/500 compliance from calibrated lux.
2. Where meter_lux exists: accuracy summary per model per source —
   BOTH raw MAPE and calibrated MAPE side by side, with bias
   direction; flag calibrated errors above 15%.
3. A compliance protocol: for each point state whether it meets 250 lx
   and 500 lx (common workplace minimums) using calibrated lux; note
   any disagreement with classifier labels and explain it via the
   calibration effect.
4. If multi5 corner columns are present: report illuminance uniformity
   (min/max across the 5 points) per measurement; flag values below
   0.7.
5. End with a short plain-language summary suitable for a workplace
   lighting report, plus any data-quality caveats you notice.

CAVEATS TO STATE
These are ML estimates from smartphone photos, intended for screening;
they do not replace certified photometric instruments. Accuracy is best
on white paper under the documented protocol (45 deg, ~31 cm height)
with per-device calibration applied.
''';

  Future<void> _createLog() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('New log file',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'e.g. office_R3_led',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Create', style: TextStyle(color: _green))),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await MeasurementLog.createLog(name);
    await _refresh();
  }

  int _col(String name) => _header.indexOf(name);

  String _cell(List<String> row, String colName) {
    final i = _col(colName);
    return (i >= 0 && i < row.length) ? row[i] : '';
  }

  Future<void> _deleteRow(int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Delete this row?',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '${_cell(_rows[index], "timestamp")}\n'
          '${_cell(_rows[index], "image")}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    await MeasurementLog.deleteRow(_selected, index);
    await _refresh();
  }

  void _showRowDetails(List<String> row) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, ctl) => ListView.builder(
          controller: ctl,
          padding: const EdgeInsets.all(16),
          itemCount: _header.length,
          itemBuilder: (_, i) {
            final v = i < row.length ? row[i] : '';
            if (v.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 190,
                    child: Text(_header[i],
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                  ),
                  Expanded(
                    child: Text(v,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12)),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Measurement logs', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            onPressed: _shareLog,
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Send this log (email/Telegram/...)',
          ),
          IconButton(
            onPressed: _createLog,
            icon: const Icon(Icons.add),
            tooltip: 'New log file',
          ),
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : Column(
              children: [
                // ── Log selector ──────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Row(children: [
                    const Text('Active log:',
                        style:
                            TextStyle(color: Colors.white54, fontSize: 13)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButton<String>(
                        value: _selected,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF1A1A1A),
                        style: const TextStyle(color: _green, fontSize: 14),
                        underline:
                            Container(height: 1, color: Colors.white24),
                        items: _logs
                            .map((l) => DropdownMenuItem(
                                value: l, child: Text(l)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) _switchLog(v);
                        },
                      ),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_rows.length} measurement(s) · new results are '
                      'appended to this file',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ),
                ),
                const SizedBox(height: 6),

                // ── Rows ─────────────────────────────────────────────
                Expanded(
                  child: _rows.isEmpty
                      ? const Center(
                          child: Text('No measurements in this log yet',
                              style: TextStyle(color: Colors.white38)))
                      : ListView.builder(
                          itemCount: _rows.length,
                          itemBuilder: (_, i) {
                            final row = _rows[i];
                            final ts = _cell(row, 'timestamp');
                            final time = ts.length >= 16
                                ? ts.substring(5, 16).replaceAll('T', ' ')
                                : ts;
                            final meter = _cell(row, 'meter_lux');
                            final room = _cell(row, 'room_id');
                            final lamp = _cell(row, 'lamp_type');
                            final src = _cell(row, 'source');
                            return Container(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A1A1A),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ListTile(
                                dense: true,
                                onTap: () => _showRowDetails(row),
                                title: Text(
                                  [
                                    time,
                                    if (meter.isNotEmpty) '$meter lx',
                                    src,
                                  ].join(' · '),
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13),
                                ),
                                subtitle: Text(
                                  [
                                    if (room.isNotEmpty) 'room $room',
                                    if (lamp.isNotEmpty) lamp,
                                    _cell(row, 'image'),
                                  ].join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 11),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.redAccent, size: 20),
                                  onPressed: () => _deleteRow(i),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
