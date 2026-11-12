// lib/screens/results_screen.dart
//
// Shown after every capture or upload. Displays:
//   - the analyzed photo with the ROI geometry painted on top
//     (central 256px ROI, 4 corner ROIs, square context bbox)
//   - every model's result (regressors as lux, classifiers as pass/fail)
//   - a small form (meter lux / room / lamp / surface / note) whose values
//     are appended together with all model outputs to measurements_log.csv

import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/calibration_service.dart';
import '../services/inference_service.dart';
import '../services/measurement_log.dart';
import '../services/photo_saver.dart';

const _green = Color(0xFF1D9E75);

class ResultsScreen extends StatefulWidget {
  final String imagePath;
  final String source; // 'capture' | 'upload'
  final AllModelsRun run;
  final double heightCm; // camera height (from the height chip)
  final String? posLabel; // flat-field frame position (POS mode), if any
  final double? angleDeg; // measured tilt (angle-free mode), if any

  const ResultsScreen({
    super.key,
    required this.imagePath,
    required this.source,
    required this.run,
    this.heightCm = 31.0,
    this.posLabel,
    this.angleDeg,
  });

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  final _meterCtl = TextEditingController();
  final _roomCtl = TextEditingController();
  final _lampCtl = TextEditingController();
  final _surfaceCtl = TextEditingController(text: 'white_paper');
  final _noteCtl = TextEditingController();
  final _ulCtl = TextEditingController();
  final _urCtl = TextEditingController();
  final _lrCtl = TextEditingController();
  final _llCtl = TextEditingController();
  bool _saving = false;
  bool _savingPhoto = false;
  bool _savingReport = false;
  String? _savedPath;
  String? _savedPhotoName;
  String? _savedReportName;
  final _reportKey = GlobalKey();
  String _activeLogName = MeasurementLog.defaultLog;
  Map<String, CalibrationFit> _fits = {};
  bool _calEnabled = true;
  String _calProfile = CalibrationService.defaultProfile;

  @override
  void initState() {
    super.initState();
    // Height flows automatically into the log's note and the saved-photo
    // filename — no more typing "47 cm" by hand (still editable).
    _noteCtl.text = '${widget.heightCm.round()} cm';
    MeasurementLog.activeLog().then((name) {
      if (mounted) setState(() => _activeLogName = name);
    });
    CalibrationService.fitsForSource(widget.source).then((f) {
      if (mounted) setState(() => _fits = f);
    });
    CalibrationService.isEnabled().then((e) {
      if (mounted) setState(() => _calEnabled = e);
    });
    CalibrationService.activeProfile().then((p) {
      if (mounted) setState(() => _calProfile = p);
    });
  }

  Future<void> _saveAsCalibrationPoint() async {
    final meter = double.tryParse(_meterCtl.text.replaceAll(',', '.'));
    if (meter == null || meter <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Enter the lux meter value first')));
      return;
    }
    final preds = <String, double>{};
    widget.run.results.forEach((name, r) {
      if (r.luxEstimate != null) preds[name] = r.luxEstimate!;
    });
    if (preds.isEmpty) return;
    final n = await CalibrationService.addPoint(
      timestamp: DateTime.now().toIso8601String(),
      source: widget.source,
      meterLux: meter,
      preds: preds,
    );
    final fits = await CalibrationService.fitsForSource(widget.source);
    if (!mounted) return;
    setState(() => _fits = fits);
    final need = CalibrationService.minPoints - n;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: _green,
      content: Text(need > 0
          ? 'Calibration point saved ($n for ${widget.source}) — '
            '$need more needed for a fit'
          : 'Calibration point saved ($n for ${widget.source}) — '
            'fit updated'),
    ));
  }

  @override
  void dispose() {
    _meterCtl.dispose();
    _roomCtl.dispose();
    _lampCtl.dispose();
    _surfaceCtl.dispose();
    _noteCtl.dispose();
    _ulCtl.dispose();
    _urCtl.dispose();
    _lrCtl.dispose();
    _llCtl.dispose();
    super.dispose();
  }

  double? _parseLux(TextEditingController ctl) {
    final v = double.tryParse(ctl.text.replaceAll(',', '.'));
    return (v != null && v > 0) ? v : null;
  }

  /// Snapshots the annotated photo (ROI overlay + footer) as an evidence
  /// image into report_photos/ — the reproducibility record showing WHERE
  /// lux was estimated and what the values were.
  Future<void> _saveReportPhoto() async {
    setState(() => _savingReport = true);
    try {
      final boundary = _reportKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('overlay not ready');
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw Exception('PNG encode failed');
      final file = await PhotoSaver.saveReportPng(
        data.buffer.asUint8List(),
        luxC: _parseLux(_meterCtl),
      );
      if (!mounted) return;
      final name = file.uri.pathSegments.last;
      setState(() => _savedReportName = name);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: _green,
        content: Text('Report saved: $name',
            style: const TextStyle(fontSize: 12)),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.red,
        content: Text('Report save failed: $e'),
      ));
    } finally {
      if (mounted) setState(() => _savingReport = false);
    }
  }

  /// Copies the photo into dataset_photos/ under a dataset-style filename
  /// encoding the entered lux values, surface and lamp type.
  Future<void> _savePhotoForDataset() async {
    final luxC = _parseLux(_meterCtl);
    final corners = [_ulCtl, _urCtl, _lrCtl, _llCtl].map(_parseLux).toList();
    if (luxC == null && corners.any((v) => v != null)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Corner lux entered without the center value — '
              'fill "Meter lux" (C) first')));
      return;
    }
    setState(() => _savingPhoto = true);
    try {
      final file = await PhotoSaver.save(
        imagePath: widget.imagePath,
        source: widget.source,
        luxC: luxC,
        luxUL: corners[0],
        luxUR: corners[1],
        luxLR: corners[2],
        luxLL: corners[3],
        surface: _surfaceCtl.text,
        lampType: _lampCtl.text,
        note: _noteCtl.text,
        heightCm: widget.heightCm,
        position: widget.posLabel,
        angleDeg: widget.angleDeg,
      );
      if (!mounted) return;
      final name = file.uri.pathSegments.last;
      setState(() => _savedPhotoName = name);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: _green,
        content: Text('Photo saved: $name',
            style: const TextStyle(fontSize: 12)),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.red,
        content: Text('Photo save failed: $e'),
      ));
    } finally {
      if (mounted) setState(() => _savingPhoto = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Calibrated value per regressor (active profile & source), so the
      // CSV carries BOTH raw and calibrated columns for any analyst.
      final calibrated = <String, double>{};
      widget.run.results.forEach((name, res) {
        final fit = _fits[name];
        double? raw;
        if (name.startsWith('et_multi')) {
          raw = res.luxByPoint?['C'];
        } else {
          raw = res.luxEstimate;
        }
        if (fit != null && raw != null) {
          calibrated[name] = fit.apply(raw);
        }
      });
      final file = await MeasurementLog.append(
        imageName: widget.imagePath.split(Platform.pathSeparator).last,
        source: widget.source,
        results: widget.run.results,
        calibrated: calibrated,
        meterLux: double.tryParse(_meterCtl.text.replaceAll(',', '.')),
        roomId: _roomCtl.text.trim(),
        lampType: _lampCtl.text.trim(),
        surface: _surfaceCtl.text.trim(),
        note: _noteCtl.text.trim(),
      );
      if (!mounted) return;
      setState(() => _savedPath = file.path);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: _green,
        content: Text('Saved to ${file.path}',
            style: const TextStyle(fontSize: 12)),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.red,
        content: Text('Save failed: $e'),
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showHelp(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (_, ctl) => ListView(
          controller: ctl,
          padding: const EdgeInsets.all(20),
          children: const [
            Text('Understanding the results',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 14),
            Text('LUX ESTIMATES',
                style: TextStyle(
                    color: Color(0xFF1D9E75),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5)),
            SizedBox(height: 6),
            Text(
              'Each row is a different AI model estimating the illuminance '
              '(in lux) at the CENTER of the photographed area. Models '
              'differ in what they were trained on:\n\n'
              '• "white paper" models — expect a white paper sheet in the '
              'frame (the standard method). Most accurate; use these as '
              'the primary result.\n'
              '• "table" models — trained on bare table surfaces.\n'
              '• "white+table" models — trained on both; a compromise.\n'
              '• "8×8" models analyze the finest spatial grid and are the '
              'recommended default.\n\n'
              'If a calibration has been set up on this phone, the large '
              'number is the CALIBRATED estimate and the raw model output '
              'is shown underneath. Calibrated values are the ones to use.',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            SizedBox(height: 16),
            Text('THRESHOLD CHECKS',
                style: TextStyle(
                    color: Color(0xFF1D9E75),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5)),
            SizedBox(height: 6),
            Text(
              'These answer a simpler question: is the light level ABOVE '
              'or BELOW a fixed threshold (200, 250 or 500 lux — common '
              'workplace minimums)? "p" is the model\'s confidence that '
              'the level is above the threshold (1.00 = certain above, '
              '0.00 = certain below; values near 0.50 mean the light is '
              'close to the threshold). These checks are more robust than '
              'exact lux estimates and are recommended for compliance '
              'screening.',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            SizedBox(height: 16),
            Text('WHICH MODEL TO TRUST',
                style: TextStyle(
                    color: Color(0xFF1D9E75),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5)),
            SizedBox(height: 6),
            Text(
              'Recommended default: "8x8 white paper" for the lux value, '
              'plus the threshold checks for compliance decisions.\n\n'
              'GEOMETRY MATTERS: models whose names mention 5 ROIs or the '
              '5-point map sample the CORNERS of the dashed region. Those '
              'corner boxes must land ON the paper — if the dashed region '
              'is larger than your sheet, corner-based results degrade '
              'silently. The 8x8 models analyze the same dashed region as '
              'a fine grid and are the most robust choice with a standard '
              'A4 sheet. Check the overlay on this screen: the dashed box '
              'should lie fully on the paper.',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            SizedBox(height: 16),
            Text('HOW TO SHOOT',
                style: TextStyle(
                    color: Color(0xFF1D9E75),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5)),
            SizedBox(height: 6),
            Text(
              'Place a white paper sheet (A4) on the work surface. Hold '
              'the phone about 31 cm above it, tilted 45° (the camera '
              'screen shows the angle), with the paper centered in the '
              'guide frame. Avoid casting your own shadow on the paper.\n\n'
              'For scientific comparison, enter the reading of a real lux '
              'meter placed at the paper center into "Meter lux" before '
              'saving — this is how the app\'s accuracy is evaluated and '
              'how calibration for this phone is built.',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            SizedBox(height: 16),
            Text('ABOUT THE MODELS',
                style: TextStyle(
                    color: Color(0xFF1D9E75),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5)),
            SizedBox(height: 6),
            Text(
              'All models were trained on an open dataset of 5,814 '
              'smartphone photographs with paired lux-meter measurements '
              '(Samsung Galaxy A16, fixed capture protocol).\n\n'
              'Dataset: https://doi.org/10.5281/zenodo.20657011\n'
              'Code: https://github.com/buryianton/ai-lux-estimation\n\n'
              'Research project by Anton Buryi, CSUN Environmental & '
              'Occupational Health. Estimates are for screening purposes '
              'and do not replace certified photometric instruments.',
              style: TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4),
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // How many of THIS run's models have a fit in the active profile —
    // the number that actually matters for calibration of this result.
    final relevantFits = widget.run.results.keys
        .where((n) => _fits.containsKey(n))
        .length;
    final luxModels = widget.run.results.values
        .where((r) => r.classLabel == null)
        .length;
    // Per-ROI lux map from the multi-output model (calibrated when a fit
    // exists for it) — drawn directly on the photo overlay.
    Map<String, double>? roiLux;
    final multi = widget.run.results['et_multi5_white_paper'];
    if (multi?.luxByPoint != null) {
      final fit = _fits['et_multi5_white_paper'];
      roiLux = multi!.luxByPoint!
          .map((k, v) => MapEntry(k, fit?.apply(v) ?? v));
    }
    double? uniformity;
    if (roiLux != null && roiLux.isNotEmpty) {
      final v = roiLux.values;
      final mx = v.reduce((a, b) => a > b ? a : b);
      if (mx > 0) uniformity = v.reduce((a, b) => a < b ? a : b) / mx;
    }

    // If every model in this run uses the small-area geometry, draw the
    // shrunken box + center ROI instead of the full 5-ROI layout.
    final smallOnly = widget.run.results.keys.isNotEmpty &&
        widget.run.results.keys.every((n) =>
            n.startsWith('et_s8_') ||
            n.startsWith('clf_s8_') ||
            n.startsWith('cnn_s8_') ||
            n.startsWith('et_c1_'));

    final regressors = <MapEntry<ModelInfo, InferenceResult>>[];
    final classifiers = <MapEntry<ModelInfo, InferenceResult>>[];
    for (final m in InferenceService.availableModels) {
      final r = widget.run.results[m.name];
      if (r == null) continue;
      (r.classLabel != null ? classifiers : regressors)
          .add(MapEntry(m, r));
    }

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Results · ${widget.source}',
            style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'What do these numbers mean?',
            onPressed: () => _showHelp(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ── Calibration status banner ─────────────────────────────────
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: !_calEnabled
                      ? Colors.white38
                      : relevantFits > 0
                          ? _green
                          : Colors.orangeAccent,
                  width: 1),
            ),
            child: Text(
              !_calEnabled
                  ? 'Calibration OFF — raw values shown and logged'
                  : _fits.isEmpty
                      ? 'Calibration ON but NO FIT for profile '
                          '"$_calProfile" / ${widget.source} — raw values '
                          'shown! Import or collect calibration points.'
                      : relevantFits == 0
                          ? 'Calibration ON but profile "$_calProfile" '
                              'has NO FIT for the models in this run — '
                              'raw values! Switch profile or calibrate '
                              'these models.'
                          : 'Calibration ON · profile "$_calProfile" · '
                              '$relevantFits of $luxModels lux model(s) '
                              'calibrated',
              style: TextStyle(
                  color: !_calEnabled
                      ? Colors.white54
                      : relevantFits > 0
                          ? _green
                          : Colors.orangeAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
          // ── Photo with ROI overlay (RepaintBoundary = report snapshot) ──
          RepaintBoundary(
            key: _reportKey,
            child: Column(children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(8)),
                child: AspectRatio(
                  // reference geometry is portrait 3072x4080 = 3:4
                  aspectRatio: 3 / 4,
                  child: Stack(fit: StackFit.expand, children: [
                    Image.file(File(widget.imagePath), fit: BoxFit.cover),
                    CustomPaint(painter: _RoiOverlayPainter(
                        roiLux: roiLux, smallArea: smallOnly)),
                  ]),
                ),
              ),
              // Evidence footer — burned into the report snapshot.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: const BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(8)),
                ),
                child: Builder(builder: (_) {
                  final e = regressors.isNotEmpty ? regressors.first : null;
                  final raw = e?.value.luxEstimate;
                  final fit = e == null ? null : _fits[e.key.name];
                  final cal = (fit != null && raw != null)
                      ? fit.apply(raw)
                      : null;
                  final val = e == null
                      ? ''
                      : ' · ${e.key.displayName}: '
                          '${(cal ?? raw)!.toStringAsFixed(0)} lx'
                          '${cal != null ? " (cal)" : " (raw)"}';
                  final ts = DateTime.now().toIso8601String();
                  return Text(
                    'AI Lux · ${InferenceService.deviceModel} · '
                    '${ts.substring(0, 16).replaceFirst("T", " ")} · '
                    '${widget.source}$val',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 9),
                  );
                }),
              ),
            ]),
          ),
          const SizedBox(height: 6),
          const Text(
            'Green: central ROI · Amber: corner ROIs · '
            'Dashed: analysis region (5×5 / 8×8 grid)',
            style: TextStyle(color: Colors.white38, fontSize: 11),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),

          // ── Regression results ────────────────────────────────────────
          const _SectionTitle('Lux estimates'),
          if (uniformity != null)
            _ResultTile(
              title: 'Illuminance uniformity',
              subtitle: 'min/max across the 5 predicted points',
              trailing: Text(
                uniformity.toStringAsFixed(2),
                style: const TextStyle(
                    color: _green,
                    fontSize: 18,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ...regressors.map((e) {
            final raw = e.value.luxEstimate!;
            final fit = _fits[e.key.name];
            final cal = fit?.apply(raw);
            return _ResultTile(
              title: e.key.displayName,
              subtitle: e.key.description,
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${(cal ?? raw).toStringAsFixed(0)} lx',
                    style: const TextStyle(
                        color: _green,
                        fontSize: 18,
                        fontWeight: FontWeight.w600),
                  ),
                  if (cal != null)
                    Text('raw ${raw.toStringAsFixed(0)} · calibrated',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 10)),
                ],
              ),
            );
          }),
          const SizedBox(height: 12),

          // ── Classifier results ────────────────────────────────────────
          // ── Derived verdicts: calibrated regression vs thresholds ──
          // On the capture path the calibrated regression is the reliable
          // compliance signal (classifiers cannot be calibrated).
          Builder(builder: (context) {
            final prim = _fits['et_s8_white_paper'] != null
                ? 'et_s8_white_paper'
                : _fits['et_v2b_white_paper'] != null
                    ? 'et_v2b_white_paper'
                    : null;
            final res = prim == null ? null : widget.run.results[prim];
            final raw = res?.luxEstimate;
            if (prim == null || raw == null) {
              return const SizedBox.shrink();
            }
            final cal = _fits[prim]!.apply(raw);
            Widget verdict(int thr) {
              final above = cal >= thr;
              return Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: above ? _green : Colors.redAccent),
                ),
                child: Text(
                  '>=$thr lx: ${above ? "YES" : "NO"}',
                  style: TextStyle(
                      color: above ? _green : Colors.redAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'Compliance by calibrated measurement '
                      '(${cal.toStringAsFixed(0)} lx)',
                      style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Row(children: [verdict(250), verdict(500)]),
                ],
              ),
            );
          }),
          const _SectionTitle('Threshold checks'),
          ...classifiers.map((e) {
            final pass = e.value.classLabel == 1;
            final prob = e.value.classProbability ?? 0;
            return _ResultTile(
              title: e.key.displayName,
              subtitle: 'p = ${prob.toStringAsFixed(3)}',
              trailing: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (pass ? _green : Colors.redAccent).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: pass ? _green : Colors.redAccent, width: 1),
                ),
                child: Text(pass ? 'ABOVE' : 'BELOW',
                    style: TextStyle(
                        color: pass ? _green : Colors.redAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            );
          }),
          const SizedBox(height: 18),

          // ── Field log form ────────────────────────────────────────────
          const _SectionTitle('Log this measurement'),
          Row(children: [
            Expanded(
                child: _Field(
                    controller: _meterCtl,
                    label: 'Meter lux',
                    keyboard: TextInputType.number)),
            const SizedBox(width: 8),
            Expanded(child: _Field(controller: _roomCtl, label: 'Room ID')),
          ]),
          const SizedBox(height: 8),
          // Optional corner meter readings (5-point sessions). Order matches
          // the dataset convention and the on-screen ROI layout.
          Row(children: [
            Expanded(
                child: _Field(
                    controller: _ulCtl,
                    label: 'UL lux',
                    keyboard: TextInputType.number)),
            const SizedBox(width: 8),
            Expanded(
                child: _Field(
                    controller: _urCtl,
                    label: 'UR lux',
                    keyboard: TextInputType.number)),
            const SizedBox(width: 8),
            Expanded(
                child: _Field(
                    controller: _lrCtl,
                    label: 'LR lux',
                    keyboard: TextInputType.number)),
            const SizedBox(width: 8),
            Expanded(
                child: _Field(
                    controller: _llCtl,
                    label: 'LL lux',
                    keyboard: TextInputType.number)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: _Field(controller: _lampCtl, label: 'Lamp type')),
            const SizedBox(width: 8),
            Expanded(
                child: _Field(controller: _surfaceCtl, label: 'Surface')),
          ]),
          const SizedBox(height: 8),
          _Field(controller: _noteCtl, label: 'Note (optional)'),
          const SizedBox(height: 14),
          SizedBox(
            height: 46,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                  backgroundColor: _green, foregroundColor: Colors.white),
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.save_alt),
              label: Text('Append to $_activeLogName'),
            ),
          ),
          if (_savedPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Log file: $_savedPath',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
            ),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: OutlinedButton.icon(
              onPressed: _saving ? null : _saveAsCalibrationPoint,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.amber,
                side: const BorderSide(color: Colors.amber, width: 1),
              ),
              icon: const Icon(Icons.tune, size: 18),
              label: Text(
                  'Save as calibration point (${widget.source})'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: OutlinedButton.icon(
              onPressed: _savingPhoto ? null : _savePhotoForDataset,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.lightBlueAccent,
                side: const BorderSide(
                    color: Colors.lightBlueAccent, width: 1),
              ),
              icon: _savingPhoto
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.lightBlueAccent, strokeWidth: 2))
                  : const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('Save photo for dataset'),
            ),
          ),
          if (_savedPhotoName != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  'Saved to ${PhotoSaver.folder}/$_savedPhotoName',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
            ),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: OutlinedButton.icon(
              onPressed: _savingReport ? null : _saveReportPhoto,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white38, width: 1),
              ),
              icon: _savingReport
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white70, strokeWidth: 2))
                  : const Icon(Icons.fact_check_outlined, size: 18),
              label: const Text('Save report photo (with points)'),
            ),
          ),
          if (_savedReportName != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  'Report: ${PhotoSaver.reportFolder}/$_savedReportName',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4)),
      );
}

class _ResultTile extends StatelessWidget {
  final String title, subtitle;
  final Widget trailing;
  const _ResultTile(
      {required this.title, required this.subtitle, required this.trailing});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 14)),
                Text(subtitle,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
          trailing,
        ]),
      );
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final TextInputType? keyboard;
  const _Field(
      {required this.controller, required this.label, this.keyboard});
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: keyboard,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
          isDense: true,
          filled: true,
          fillColor: const Color(0xFF1A1A1A),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.white24)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: _green)),
        ),
      );
}

/// Paints the training ROI geometry over the displayed photo.
/// The photo is shown BoxFit.cover inside a 3:4 box, and the reference
/// image is itself 3:4 (3072x4080), so simple fractional coordinates map
/// 1:1 onto the displayed area.
class _RoiOverlayPainter extends CustomPainter {
  final Map<String, double>? roiLux; // per-ROI lux to draw (optional)
  final bool smallArea; // shrunken-geometry run: box + center only
  _RoiOverlayPainter({this.roiLux, this.smallArea = false});

  static const _refW = 3072.0, _refH = 4080.0;
  static const _centers = {
    'C': Offset(1520, 2027),
    'UL': Offset(1020, 1372),
    'UR': Offset(2043, 1372),
    'LR': Offset(2030, 2722),
    'LL': Offset(1020, 2722),
  };
  static const _sizes = {'C': 256.0, 'UL': 128.0, 'UR': 128.0,
                         'LR': 128.0, 'LL': 128.0};

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / _refW;
    final sy = size.height / _refH;

    Rect roiRect(String k) {
      final c = _centers[k]!;
      final s = _sizes[k]!;
      return Rect.fromCenter(
          center: Offset(c.dx * sx, c.dy * sy),
          width: s * sx,
          height: s * sy);
    }

    // Square context bbox = tight bbox around the 4 corner ROIs
    final corners = ['UL', 'UR', 'LR', 'LL'].map(roiRect).toList();
    var bbox = corners.first;
    for (final r in corners.skip(1)) {
      bbox = bbox.expandToInclude(r);
    }
    if (smallArea) {
      // 65% of the bbox, centered — plus the central ROI, nothing else.
      final small = Rect.fromCenter(
          center: bbox.center,
          width: bbox.width * 0.65,
          height: bbox.height * 0.65);
      _drawDashedRect(canvas, small, Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2);
      final cPaint = Paint()
        ..color = _green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      final cRect = roiRect('C');
      canvas.drawRect(cRect, cPaint);
      _label(canvas, 'C', cRect.topLeft + const Offset(2, -14),
          const TextStyle(color: _green, fontSize: 10));
      return;
    }

    // dashed context box
    final dashPaint = Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    _drawDashedRect(canvas, bbox, dashPaint);

    // corner ROIs (amber)
    final cornerPaint = Paint()
      ..color = Colors.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    final labelStyle = const TextStyle(color: Colors.amber, fontSize: 10);
    for (final k in ['UL', 'UR', 'LR', 'LL']) {
      final r = roiRect(k);
      canvas.drawRect(r, cornerPaint);
      _label(canvas, k, r.topLeft + const Offset(2, -14), labelStyle);
    }

    // central ROI (green)
    final cPaint = Paint()
      ..color = _green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final cRect = roiRect('C');
    canvas.drawRect(cRect, cPaint);
    _label(canvas, 'C', cRect.topLeft + const Offset(2, -14),
        const TextStyle(color: _green, fontSize: 10));

    // per-ROI predicted lux value chips (multi-output model)
    if (roiLux != null) {
      for (final k in ['C', 'UL', 'UR', 'LR', 'LL']) {
        final v = roiLux![k];
        if (v == null) continue;
        final r = roiRect(k);
        _valueChip(canvas, '${v.round()} lx',
            Offset(r.center.dx, r.bottom + 4),
            k == 'C' ? _green : Colors.amber);
      }
    }
  }

  void _valueChip(Canvas canvas, String text, Offset topCenter, Color c) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
        center: Offset(topCenter.dx, topCenter.dy + tp.height / 2 + 3),
        width: tp.width + 10,
        height: tp.height + 6);
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = Colors.black.withOpacity(0.65));
    tp.paint(canvas, rect.topLeft + const Offset(5, 3));
  }

  void _label(Canvas canvas, String text, Offset at, TextStyle style) {
    final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, at);
  }

  void _drawDashedRect(Canvas canvas, Rect r, Paint p,
      {double dash = 6, double gap = 4}) {
    final path = Path()..addRect(r);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), p);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
