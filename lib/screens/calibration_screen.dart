// lib/screens/calibration_screen.dart
//
// Calibration manager with PROFILES:
//   - master switch: calibration on/off (off = raw values everywhere)
//   - profile dropdown + "+" to create one per lighting context
//     (e.g. office_led, home_warm, lab_fluorescent)
//   - fit status per source for the ACTIVE profile
//   - points list of the active profile with per-point delete
//
// Points are ADDED from the results screen ("Save as calibration
// point") — they always go into the active profile.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/calibration_service.dart';

const _green = Color(0xFF1D9E75);

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  List<CalibrationPoint> _all = [];
  List<String> _profiles = [CalibrationService.defaultProfile];
  String _active = CalibrationService.defaultProfile;
  bool _enabled = true;
  Map<String, CalibrationFit> _captureFits = {};
  Map<String, CalibrationFit> _uploadFits = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final all = await CalibrationService.loadPoints();
    final profiles = await CalibrationService.listProfiles();
    final active = await CalibrationService.activeProfile();
    final enabled = await CalibrationService.isEnabled();
    final cf = await CalibrationService.fitsFor(active, 'capture');
    final uf = await CalibrationService.fitsFor(active, 'upload');
    if (!mounted) return;
    setState(() {
      _all = all;
      _profiles = profiles;
      _active = active;
      _enabled = enabled;
      _captureFits = cf;
      _uploadFits = uf;
      _loading = false;
    });
  }

  /// Points of the active profile with their GLOBAL indices for delete.
  List<(int, CalibrationPoint)> get _activePoints => [
        for (var i = 0; i < _all.length; i++)
          if (_all[i].profile == _active) (i, _all[i])
      ];

  Future<void> _newProfile() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('New calibration profile',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'e.g. office_led, home_warm',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Create', style: TextStyle(color: _green))),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await CalibrationService.setActiveProfile(name);
    await _refresh();
  }

  Future<void> _importCalibration() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Import calibration',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Open the calibration .json file you received (e.g. in '
              'Telegram: tap the file, open as text), copy ALL of its '
              'content, and paste it below.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctl,
              maxLines: 6,
              style: const TextStyle(color: Colors.white, fontSize: 11),
              decoration: InputDecoration(
                hintText: '{ ... } or [ ... ]',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF111111),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste,
                      color: Colors.white54, size: 20),
                  tooltip: 'Paste from clipboard',
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text != null) ctl.text = data!.text!;
                  },
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import', style: TextStyle(color: _green))),
        ],
      ),
    );
    if (ok != true || ctl.text.trim().isEmpty) return;
    try {
      final msg = await CalibrationService.importJson(ctl.text.trim());
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: _green, content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Import failed: $e')));
    }
  }

  Future<void> _shareCalibration() async {
    final files = await CalibrationService.exportFiles();
    final existing = <XFile>[];
    for (final f in files) {
      if (await f.exists()) existing.add(XFile(f.path));
    }
    if (existing.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No calibration data to send yet')));
      return;
    }
    await Share.shareXFiles(existing,
        subject: 'AI Lux calibration data',
        text: 'AI Lux calibration points, fitted parameters, settings');
  }

  Future<void> _clearProfile() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('Delete all points of "$_active"?',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text('Other profiles are not affected.',
            style: TextStyle(color: Colors.white54, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true) {
      await CalibrationService.clearProfile(_active);
      await _refresh();
    }
  }

  Future<void> _deleteGlobal(int globalIndex) async {
    await CalibrationService.deletePoint(globalIndex);
    await _refresh();
  }

  final GlobalKey _plotKey = GlobalKey();

  Future<void> _showCurve() async {
    final models = {..._captureFits.keys, ..._uploadFits.keys}.toList()
      ..sort();
    if (models.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No fitted curves yet — add calibration points')));
      return;
    }
    var model = models.contains('et_s8_white_paper')
        ? 'et_s8_white_paper'
        : models.first;
    var source = _captureFits.containsKey(model) ? 'capture' : 'upload';
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final fits = source == 'capture' ? _captureFits : _uploadFits;
        final fit = fits[model];
        final pts = [
          for (final e in _activePoints)
            if (e.$2.source == source && e.$2.preds.containsKey(model))
              (e.$2.preds[model]!, e.$2.meterLux)
        ];
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          contentPadding: const EdgeInsets.all(12),
          content: SizedBox(
            width: 340,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButton<String>(
                value: model,
                isExpanded: true,
                dropdownColor: const Color(0xFF1A1A1A),
                style: const TextStyle(color: _green, fontSize: 13),
                items: models
                    .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
                onChanged: (v) => setD(() => model = v ?? model),
              ),
              Row(children: [
                for (final s in ['capture', 'upload'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(s),
                      selected: source == s,
                      selectedColor: _green,
                      onSelected: (_) => setD(() => source = s),
                    ),
                  ),
              ]),
              const SizedBox(height: 8),
              RepaintBoundary(
                key: _plotKey,
                child: Container(
                  color: const Color(0xFF111111),
                  width: 320,
                  height: 300,
                  child: fit == null
                      ? const Center(
                          child: Text('No fit for this selection',
                              style: TextStyle(color: Colors.white38)))
                      : CustomPaint(
                          painter: _CurvePainter(
                              fit: fit,
                              points: pts,
                              title: '$model · $source · '
                                  '${_active} · n=${fit.n}'),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close',
                        style: TextStyle(color: Colors.white54))),
                TextButton.icon(
                    onPressed: fit == null ? null : _exportPlot,
                    icon: const Icon(Icons.share_outlined,
                        color: _green, size: 18),
                    label: const Text('Export PNG',
                        style: TextStyle(color: _green))),
              ]),
            ]),
          ),
        );
      }),
    );
  }

  Future<void> _exportPlot() async {
    try {
      final boundary = _plotKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final img = await boundary.toImage(pixelRatio: 3.0);
      final bytes =
          (await img.toByteData(format: ui.ImageByteFormat.png))!;
      final dir = await getTemporaryDirectory();
      final f = File(
          '${dir.path}${Platform.pathSeparator}calibration_curve.png');
      await f.writeAsBytes(bytes.buffer.asUint8List());
      await Share.shareXFiles([XFile(f.path)],
          subject: 'AI Lux calibration curve');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')));
    }
  }

  Widget _statusCard(String source, Map<String, CalibrationFit> fits) {
    final n =
        _activePoints.where((e) => e.$2.source == source).length;
    final fitted = fits.isNotEmpty;
    final sample = fitted ? fits.values.first : null;
    final need = CalibrationService.minPoints - n;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
        border:
            Border.all(color: fitted ? _green : Colors.white24, width: 1),
      ),
      child: Row(children: [
        Icon(fitted ? Icons.check_circle : Icons.radio_button_unchecked,
            color: fitted ? _green : Colors.white38, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${source[0].toUpperCase()}${source.substring(1)} path',
                    style:
                        const TextStyle(color: Colors.white, fontSize: 14)),
                Text(
                  fitted
                      ? 'Calibrated on $n points · ${fits.length} models '
                          '(b=${sample!.b.toStringAsFixed(3)})'
                      : '$n / ${CalibrationService.minPoints} points — '
                          'need ${need > 0 ? need : 0} more',
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pts = _activePoints;
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title:
            const Text('Device calibration', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
              onPressed: _showCurve,
              icon: const Icon(Icons.show_chart),
              tooltip: 'View / export calibration curve'),
          IconButton(
              onPressed: _importCalibration,
              icon: const Icon(Icons.file_download_outlined),
              tooltip: 'Import calibration file'),
          IconButton(
              onPressed: _shareCalibration,
              icon: const Icon(Icons.share_outlined),
              tooltip: 'Send calibration files'),
          IconButton(
              onPressed: _clearProfile,
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear this profile'),
          IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // ── Master switch ─────────────────────────────────────
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Apply calibration',
                        style:
                            TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: Text(
                      _enabled
                          ? 'Results show calibrated values'
                          : 'OFF — results show raw model output',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                    activeColor: _green,
                    value: _enabled,
                    onChanged: (v) async {
                      await CalibrationService.setEnabled(v);
                      await _refresh();
                    },
                  ),
                ),
                const SizedBox(height: 10),

                // ── Profile selector ──────────────────────────────────
                Row(children: [
                  const Text('Profile:',
                      style:
                          TextStyle(color: Colors.white54, fontSize: 13)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButton<String>(
                      value: _active,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1A1A1A),
                      style: const TextStyle(color: _green, fontSize: 14),
                      underline:
                          Container(height: 1, color: Colors.white24),
                      items: _profiles
                          .map((p) =>
                              DropdownMenuItem(value: p, child: Text(p)))
                          .toList(),
                      onChanged: (v) async {
                        if (v == null) return;
                        await CalibrationService.setActiveProfile(v);
                        await _refresh();
                      },
                    ),
                  ),
                  IconButton(
                    onPressed: _newProfile,
                    icon: const Icon(Icons.add, color: _green),
                    tooltip: 'New profile',
                  ),
                ]),
                const Text(
                  'Create one profile per lighting context (lamp type / '
                  'room). New calibration points from the results screen '
                  'go into the profile selected here; measurements are '
                  'corrected by it while it stays selected.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 12),

                _statusCard('capture', _captureFits),
                _statusCard('upload', _uploadFits),
                const SizedBox(height: 10),

                Text('Points in "$_active" (${pts.length})',
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                if (pts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                        child: Text('No points in this profile yet',
                            style: TextStyle(color: Colors.white38))),
                  ),
                ...pts.map((e) {
                  final (gi, p) = e;
                  final ref =
                      p.preds.entries.isNotEmpty ? p.preds.entries.first : null;
                  final ts = p.timestamp.length >= 16
                      ? p.timestamp.substring(5, 16).replaceAll('T', ' ')
                      : p.timestamp;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListTile(
                      dense: true,
                      title: Text(
                        '$ts · ${p.source} · meter '
                        '${p.meterLux.toStringAsFixed(0)} lx',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                      ),
                      subtitle: Text(
                        ref != null
                            ? '${p.preds.length} model predictions '
                                '(e.g. ${ref.key}: '
                                '${ref.value.toStringAsFixed(0)} lx)'
                            : 'no predictions stored',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.redAccent, size: 20),
                        onPressed: () => _deleteGlobal(gi),
                      ),
                    ),
                  );
                }),
              ],
            ),
    );
  }
}

/// Log-log plot: calibration points (pred vs meter), the fitted
/// monotone piecewise curve, and the identity line for reference.
class _CurvePainter extends CustomPainter {
  final CalibrationFit fit;
  final List<(double, double)> points;
  final String title;
  _CurvePainter({required this.fit, required this.points, required this.title});

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 40.0, padB = 28.0, padT = 22.0, padR = 10.0;
    final all = <double>[
      for (final p in points) ...[p.$1, p.$2],
      10, 3000,
    ];
    final lo = math.log(all.reduce(math.min) * 0.8);
    final hi = math.log(all.reduce(math.max) * 1.2);
    double sx(double v) =>
        padL + (math.log(v) - lo) / (hi - lo) * (size.width - padL - padR);
    double sy(double v) =>
        size.height - padB -
        (math.log(v) - lo) / (hi - lo) * (size.height - padT - padB);

    final axis = Paint()..color = Colors.white24..strokeWidth = 1;
    canvas.drawLine(Offset(padL, padT),
        Offset(padL, size.height - padB), axis);
    canvas.drawLine(Offset(padL, size.height - padB),
        Offset(size.width - padR, size.height - padB), axis);
    for (final v in [10, 50, 100, 250, 500, 1000, 2000]) {
      final x = sx(v.toDouble()), y = sy(v.toDouble());
      if (x > padL && x < size.width - padR) {
        _text(canvas, '$v', Offset(x - 8, size.height - padB + 4), 8);
      }
      if (y < size.height - padB && y > padT) {
        _text(canvas, '$v', Offset(2, y - 5), 8);
      }
    }

    // identity line
    final id = Paint()..color = Colors.white24..strokeWidth = 1;
    canvas.drawLine(Offset(sx(math.exp(lo)), sy(math.exp(lo))),
        Offset(sx(math.exp(hi)), sy(math.exp(hi))), id);

    // fitted curve
    final curve = Paint()
      ..color = const Color(0xFF1D9E75)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    var first = true;
    for (var i = 0; i <= 100; i++) {
      final raw = math.exp(lo + (hi - lo) * i / 100);
      final cal = fit.apply(raw);
      final o = Offset(sx(raw), sy(cal));
      if (first) { path.moveTo(o.dx, o.dy); first = false; }
      else { path.lineTo(o.dx, o.dy); }
    }
    canvas.drawPath(path, curve);

    // points
    final ptPaint = Paint()..color = Colors.amber;
    for (final p in points) {
      canvas.drawCircle(Offset(sx(p.$1), sy(p.$2)), 3.5, ptPaint);
    }

    _text(canvas, title, const Offset(6, 4), 9, color: Colors.white70);
    _text(canvas, 'x: raw model lux · y: meter lux · curve: fitted correction',
        Offset(padL, size.height - 12), 8);
  }

  void _text(Canvas c, String s, Offset o, double size,
      {Color color = Colors.white38}) {
    final tp = TextPainter(
        text: TextSpan(
            text: s, style: TextStyle(color: color, fontSize: size)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) =>
      old.fit != fit || old.points != points || old.title != title;
}
