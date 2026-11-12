import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import 'dart:math';

import '../services/inference_service.dart';
import '../services/photo_saver.dart';
import 'calibration_screen.dart';
import 'log_viewer_screen.dart';
import 'results_screen.dart';

// ── MethodChannel to the native Camera2Service ────────────────────────────────

const _channel = MethodChannel('com.buryi.ai_lux_app/camera2');

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  bool _cameraReady = false;
  String _error = '';
  Map<String, dynamic> _settings = {};

  // Angle tracking
  double _pitchDeg = 0.0;
  StreamSubscription? _accelSub;

  // State machine
  CaptureState _state = CaptureState.searching;

  /// Overlay geometry for the current selection: small-area models (and
  /// the all-small Fast preset) show the shrunken box + center marker;
  /// center-only models show just the center; everything else full.
  String get _geomMode {
    final m = _selectedModel;
    if (m == 'fast') return 'small'; // fast preset is all small-area
    if (m.startsWith('grp_')) return 'full'; // mixed-geometry suites
    if (m.startsWith('et_c1_')) return 'center';
    if (m.startsWith('et_s8_') ||
        m.startsWith('clf_s8_') ||
        m.startsWith('cnn_s8_')) return 'small';
    return 'full';
  }

  // Inference
  bool _isRunningInference = false;
  bool _pickerActive = false; // guards double-open of the image picker
  String _selectedModel = 'fast'; // 'fast', 'all', or a model name
  final _picker = ImagePicker();

  // Camera height selector: drives BOTH the A4 on-screen guide and the
  // height-adaptive feature extraction (constant-physical-footprint s8
  // sampling). 0 = default/off -> extraction assumes the reference 31 cm.
  // Static so the selected height survives camera-screen rebuilds (the
  // chip silently resetting to default was a mislabel hazard in sessions).
  static int _persistedGuideCm = 0;
  int get _guideCm => _persistedGuideCm;
  set _guideCm(int v) => _persistedGuideCm = v;
  static const _guideOptions = [0, 22, 31, 40, 47, 53, 56];

  double get _heightCm => _guideCm > 0 ? _guideCm.toDouble() : 31.0;

  // Flat-field position mode: 9 tappable markers; the selected one names
  // where the metered point sits in the frame and is stamped into the
  // saved filename (__POS token). For the vignetting-map sessions.
  // 0 = off, 1 = FRAME (markers fixed on screen — vignetting sessions),
  // 2 = WORLD (marker offsets scale by 31/height so each marker tracks the
  // SAME physical point on the table at any height — multi-point sessions).
  int _posModeKind = 0;
  bool get _posMode => _posModeKind > 0;
  bool get _posWorld => _posModeKind == 2;
  String? _posSel;
  static const Map<String, Offset> _posMarkers = {
    'nw': Offset(0.18, 0.16),
    'n': Offset(0.50, 0.16),
    'ne': Offset(0.82, 0.16),
    'w': Offset(0.14, 0.50),
    'c': Offset(0.50, 0.50),
    'e': Offset(0.86, 0.50),
    'sw': Offset(0.18, 0.84),
    's': Offset(0.50, 0.84),
    'se': Offset(0.82, 0.84),
    // mid ring: half offsets (~22 cm from center at 31 cm height per the
    // 2026-09-29 ruler session) — comfortable on small tables, and inside
    // the zone where the 31/h world-tracking is sub-percent accurate.
    'mn': Offset(0.50, 0.33),
    'me': Offset(0.68, 0.50),
    'ms': Offset(0.50, 0.67),
    'mw': Offset(0.32, 0.50),
  };

  // Angle-free mode: unlocks capture at any tilt (for tilt-sweep
  // sessions); the measured angle is stamped into saved filenames.
  bool _angleFree = false;

  bool get _isLocked => _angleFree
      ? (_pitchDeg >= 5 && _pitchDeg <= 85)
      : (_pitchDeg >= 42 && _pitchDeg <= 48);

  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissionThenInit();
    _initAccelerometer();
  }

  /// Volunteers install from APK: the camera permission must be requested
  /// at runtime, or the native camera silently fails (black preview —
  /// seen on MIUI). Ask first; show a friendly screen if denied.
  Future<void> _requestPermissionThenInit() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (status.isGranted) {
      setState(() => _permissionDenied = false);
      _initCamera();
    } else {
      setState(() => _permissionDenied = true);
    }
  }

  Future<void> _initCamera() async {
    try {
      final result = await _channel.invokeMethod<Map>('init');
      // Device identity + user-imported models (non-fatal if either fails)
      try {
        final dev = await _channel.invokeMethod<Map>('deviceInfo');
        InferenceService.deviceModel =
            '${dev?['manufacturer'] ?? ''} ${dev?['model'] ?? ''}'.trim();
        final dir = await _channel.invokeMethod<String>('customModelsDir');
        if (dir != null) await InferenceService.refreshCustomModels(dir);
      } catch (_) {}
      final settings = Map<String, dynamic>.from(result ?? {});
      if (mounted) {
        setState(() {
          _settings = settings;
          _cameraReady = true;
        });
      }
      // Log confirmed settings for debugging
      debugPrint('Camera2 settings: $settings');
      if (settings['iso_50_supported'] == false) {
        debugPrint('WARNING: ISO 50 may not be supported on this device!');
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'Camera init failed');
    }
  }

  void _initAccelerometer() {
    _accelSub = accelerometerEventStream().listen((event) {
      final pitch = (atan2(event.y, event.z) * 180 / pi).abs();
      setState(() {
        _pitchDeg = pitch;
        if (_isLocked && _state == CaptureState.searching) {
          _state = CaptureState.locked;
        } else if (!_isLocked && _state == CaptureState.locked) {
          _state = CaptureState.searching;
        }
      });
    });
  }

  double? _pitchAtCapture;

  Future<void> _capture() async {
    if (!_cameraReady || _state != CaptureState.locked) return;
    setState(() => _state = CaptureState.capturing);
    _pitchAtCapture = _pitchDeg;

    try {
      final imagePath = await _channel.invokeMethod<String>('capture');
      if (mounted) setState(() => _state = CaptureState.locked);
      if (imagePath != null) await _runInference(imagePath, source: 'capture');
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() => _state = CaptureState.locked);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: ${e.message}'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Flash-pair pilot capture: two stills seconds apart at the same locked
  /// exposure, torch off then torch on. The pixel difference isolates the
  /// torch's contribution = per-pixel reflectance map (flash/no-flash
  /// separation). Photos go straight to dataset_photos with FP{pair}t0/t1
  /// tokens; no inference, no results screen.
  Future<void> _captureFlashPair() async {
    if (!_cameraReady || _state != CaptureState.locked) {
      // Never swallow the tap silently - that lost a whole session's pairs.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Flash pair needs the tilt locked (green) first'),
          backgroundColor: Colors.orange));
      return;
    }
    final luxText = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Flash pair'),
        content: TextField(
          controller: luxText,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Meter lux at center (optional)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Capture pair')),
        ],
      ),
    );
    if (ok != true) return;
    final luxC = double.tryParse(luxText.text.trim());
    setState(() => _state = CaptureState.capturing);
    final pairId = (DateTime.now().millisecondsSinceEpoch % 1000000)
        .toString().padLeft(6, '0');
    try {
      final pathA = await _channel.invokeMethod<String>('capture');
      await _channel.invokeMethod('setTorch', {'on': true});
      // Let the torch output and the repeating request settle.
      await Future.delayed(const Duration(milliseconds: 1200));
      final pathB = await _channel.invokeMethod<String>('capture');
      await _channel.invokeMethod('setTorch', {'on': false});
      for (final e in [(pathA, 't0'), (pathB, 't1')]) {
        if (e.$1 == null) continue;
        await PhotoSaver.save(
          imagePath: e.$1!,
          source: 'capture',
          luxC: luxC,
          heightCm: _heightCm,
          note: 'flash pair $pairId ${e.$2 == 't0' ? 'torch off' : 'torch on'}',
          extraTag: 'FP$pairId${e.$2}',
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Flash pair FP$pairId saved to dataset photos'),
          backgroundColor: const Color(0xFF1D9E75),
        ));
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Flash pair failed: ${e.message}'),
            backgroundColor: Colors.red));
      }
    } finally {
      // Never leave the torch on, whatever happened above.
      try { await _channel.invokeMethod('setTorch', {'on': false}); }
      catch (_) {}
      if (mounted) setState(() => _state = CaptureState.locked);
    }
  }

  Future<void> _runInference(String imagePath, {required String source}) async {
    setState(() => _isRunningInference = true);
    try {
      // 'fast'/group -> suite list, 'all' -> every model, else single.
      final suite = InferenceService.modelsForSelection(_selectedModel);
      final run = await InferenceService.runAllModels(
        imagePath,
        models: suite,
        onlyModel: (suite != null || _selectedModel == 'all')
            ? null
            : _selectedModel,
        heightCm: _heightCm,
        // Native captures go through the Camera2 pipeline and need the
        // stock-domain LUT; uploads are already stock JPEGs.
        pipelineLut: source == 'capture',
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResultsScreen(
          imagePath: imagePath,
          source: source,
          run: run,
          heightCm: _heightCm,
          posLabel: !_posMode || _posSel == null
              ? null
              : (_posWorld ? 'w$_posSel' : _posSel),
          angleDeg: _angleFree && source == 'capture'
              ? _pitchAtCapture
              : null,
        ),
      ));
      // Returning from results (or from the picker) may have paused the
      // native camera — make sure it's reopened.
      if (mounted) _initCamera();
    } catch (e) {
      if (mounted) _showResult(title: 'Inference error', body: '$e', isError: true);
    } finally {
      if (mounted) setState(() => _isRunningInference = false);
    }
  }

  Future<void> _importCustomModels() async {
    try {
      final copied =
          await _channel.invokeMethod<List<dynamic>>('importModels');
      if (copied == null || copied.isEmpty) return;
      final dir = await _channel.invokeMethod<String>('customModelsDir');
      final n = dir == null
          ? 0
          : await InferenceService.refreshCustomModels(dir);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFF1D9E75),
          content: Text('Imported ${copied.length} file(s) · '
              '$n custom model(s) ready')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Import failed: $e')));
    }
  }

  Future<void> _pickAndAnalyze() async {
    if (_isRunningInference || _pickerActive) return;
    _pickerActive = true;
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked == null) {
        // user cancelled — picker still paused the app, so reopen camera
        if (mounted) _initCamera();
        return;
      }
      await _runInference(picked.path, source: 'upload');
    } on PlatformException catch (e) {
      if (e.code == 'already_active') {
        // A picker is already open (double tap / racing lifecycle) —
        // silently ignore; the open picker keeps working.
      } else if (mounted) {
        _showResult(title: 'Upload failed', body: '$e', isError: true);
      }
    } catch (e) {
      if (mounted) {
        _showResult(title: 'Upload failed', body: '$e', isError: true);
      }
    } finally {
      _pickerActive = false;
    }
  }

  void _showResult({required String title, required String body, bool isError = false}) {
    // ignore: use_build_context_synchronously
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(title,
            style: TextStyle(color: isError ? Colors.red : const Color(0xFF1D9E75))),
        content: Text(body,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Color(0xFF1D9E75))),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _channel.invokeMethod('dispose');
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accelSub?.cancel();
    _channel.invokeMethod('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.no_photography_outlined,
                    color: Colors.white38, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'Camera access is required to measure illuminance.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1D9E75),
                      foregroundColor: Colors.white),
                  onPressed: () async {
                    final status = await Permission.camera.status;
                    if (status.isPermanentlyDenied) {
                      await openAppSettings();
                    } else {
                      await _requestPermissionThenInit();
                    }
                  },
                  child: const Text('Grant camera access'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Back',
                      style: TextStyle(color: Colors.white54)),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Native Camera2 preview via PlatformView ─────────────────────
          if (_cameraReady)
            Positioned.fill(
              child: AndroidView(
                viewType: 'camera2_preview',
                layoutDirection: TextDirection.ltr,
                creationParamsCodec: const StandardMessageCodec(),
              ),
            )
          else if (_error.isNotEmpty)
            Center(child: Text(_error,
                style: const TextStyle(color: Colors.red)))
          else
            const Center(child: CircularProgressIndicator(
                color: Color(0xFF1D9E75))),

          // ── Geometry overlay ────────────────────────────────────────────
          if (_cameraReady)
            Positioned.fill(
              child: GeometryOverlay(
                  state: _state,
                  pitchDeg: _pitchDeg,
                  geomMode: _geomMode,
                  guideCm: _guideCm),
            ),

          // ── A4 height-guide toggle chip ─────────────────────────────────
          if (_cameraReady)
            Positioned(
              top: 96,
              left: 16,
              child: GestureDetector(
                onTap: () => setState(() {
                  final i = _guideOptions.indexOf(_guideCm);
                  _guideCm =
                      _guideOptions[(i + 1) % _guideOptions.length];
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _guideCm > 0
                            ? Colors.amber
                            : Colors.white24,
                        width: 1),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.height,
                        size: 14,
                        color:
                            _guideCm > 0 ? Colors.amber : Colors.white54),
                    const SizedBox(width: 5),
                    Text(
                      _guideCm > 0
                          ? 'Height $_guideCm cm'
                          : 'Height 31 cm (default)',
                      style: TextStyle(
                          color: _guideCm > 0
                              ? Colors.amber
                              : Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                    ),
                  ]),
                ),
              ),
            ),

          // ── Flat-field position-mode chip + markers ─────────────────────
          if (_cameraReady)
            Positioned(
              top: 140,
              left: 16,
              child: GestureDetector(
                onTap: () => setState(() {
                  _posModeKind = (_posModeKind + 1) % 3;
                  if (!_posMode) _posSel = null;
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _posMode
                            ? Colors.cyanAccent
                            : Colors.white24,
                        width: 1),
                  ),
                  child: Text(
                    !_posMode
                        ? 'POS mode off'
                        : '${_posWorld ? "POS WORLD" : "POS FRAME"}: '
                            '${_posSel?.toUpperCase() ?? "tap a marker"}',
                    style: TextStyle(
                        color: _posMode
                            ? Colors.cyanAccent
                            : Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
          // ── Angle-free toggle chip ──────────────────────────────────────
          if (_cameraReady)
            Positioned(
              top: 184,
              left: 16,
              child: GestureDetector(
                onTap: () => setState(() => _angleFree = !_angleFree),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _angleFree
                            ? Colors.orangeAccent
                            : Colors.white24,
                        width: 1),
                  ),
                  child: Text(
                    _angleFree
                        ? 'Angle FREE (logged)'
                        : 'Angle lock 45°',
                    style: TextStyle(
                        color: _angleFree
                            ? Colors.orangeAccent
                            : Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
          if (_cameraReady && _posMode)
            ..._posMarkers.entries.map((e) {
              final size = MediaQuery.of(context).size;
              final sel = _posSel == e.key;
              // WORLD mode: scale marker offsets from center by 31/height so
              // each marker tracks the same physical table point (same rule
              // as the constant-footprint analysis box). Ruler-calibrated
              // 2026-09-29: sub-percent at the mid ring; the FAR NORTH row
              // compresses ~8% less than 31/h at h>=40 (tilt perspective),
              // so its y-offset gets the measured correction. Other outer
              // rows await calibration (A4 homography will supersede).
              final wf = _posWorld ? 31.0 / _heightCm : 1.0;
              var ox = (e.value.dx - 0.5) * wf;
              var oy = (e.value.dy - 0.5) * wf;
              if (_posWorld && e.value.dy < 0.3) {
                final h = _heightCm;
                final corr = h <= 31
                    ? 1.0
                    : (h >= 40 ? 1.08 : 1.0 + 0.08 * (h - 31) / 9.0);
                oy *= corr;
              }
              final mx = 0.5 + ox;
              final my = 0.5 + oy;
              return Positioned(
                left: mx * size.width - 22,
                top: my * size.height - 22,
                child: GestureDetector(
                  onTap: () => setState(() => _posSel = e.key),
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: sel
                          ? Colors.cyanAccent.withValues(alpha: 0.25)
                          : Colors.black38,
                      border: Border.all(
                          color: sel
                              ? Colors.cyanAccent
                              : Colors.white38,
                          width: sel ? 2 : 1),
                    ),
                    child: Text(e.key.toUpperCase(),
                        style: TextStyle(
                            color: sel
                                ? Colors.cyanAccent
                                : Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              );
            }),

          // ── Model picker (single model or all) ─────────────────────────
          if (_cameraReady)
            Positioned(
              top: 96,
              right: 16,
              child: _ModelPickerChip(
                selectedModel: _selectedModel,
                onModelSelected: (name) {
                  if (name == '__import__') {
                    _importCustomModels();
                    return;
                  }
                  setState(() => _selectedModel = name);
                },
              ),
            ),

          // ── Settings confirmation badge ──────────────────────────────────
          if (_cameraReady && _settings.isNotEmpty)
            Positioned(
              top: 52,
              left: 16,
              child: _SettingsBadge(settings: _settings),
            ),

          // ── Inference loading overlay ───────────────────────────────────
          if (_isRunningInference)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFF1D9E75)),
                      SizedBox(height: 16),
                      Text('Running inference...',
                          style: TextStyle(color: Colors.white, fontSize: 14)),
                    ],
                  ),
                ),
              ),
            ),

          // ── Bottom controls ─────────────────────────────────────────────
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: _buildBottomBar(),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      color: Colors.black54,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              onPressed: _isRunningInference ? null : _pickAndAnalyze,
              icon: const Icon(Icons.photo_library_outlined,
                  color: Colors.white70, size: 28),
              tooltip: 'Analyze photo from gallery',
            ),
            IconButton(
              onPressed: _isRunningInference ? null : _captureFlashPair,
              icon: const Icon(Icons.flash_on_outlined,
                  color: Colors.amberAccent, size: 26),
              tooltip: 'Flash pair (torch off/on, saved to dataset)',
            ),
          ]),
          GestureDetector(
            onTap: _isRunningInference ? null : _capture,
            child: Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _state == CaptureState.locked
                    ? const Color(0xFF1D9E75) : Colors.white24,
                border: Border.all(color: Colors.white, width: 2.5),
              ),
              child: _state == CaptureState.capturing
                  ? const CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2)
                  : const SizedBox(),
            ),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const CalibrationScreen()));
                if (mounted) _initCamera();
              },
              icon: const Icon(Icons.tune,
                  color: Colors.white70, size: 24),
              tooltip: 'Device calibration',
            ),
            IconButton(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const LogViewerScreen()));
                if (mounted) _initCamera();
              },
              icon: const Icon(Icons.table_rows_outlined,
                  color: Colors.white70, size: 26),
              tooltip: 'Measurement logs',
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back,
                  color: Colors.white70, size: 28),
            ),
          ]),
        ],
      ),
    );
  }
}

// ── Settings confirmation badge (top left) ────────────────────────────────────

class _SettingsBadge extends StatelessWidget {
  final Map<String, dynamic> settings;
  const _SettingsBadge({required this.settings});

  @override
  Widget build(BuildContext context) {
    final iso = settings['iso_target'] ?? '?';
    final expNs = settings['exposure_target_ns'] as int? ?? 0;
    final expMs = expNs > 0 ? '1/${(1e9 / expNs).round()}s' : '?';
    final wbR = (settings['wb_r'] as double?)?.toStringAsFixed(2) ?? '?';
    final wbB = (settings['wb_b'] as double?)?.toStringAsFixed(2) ?? '?';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1D9E75), width: 0.8),
      ),
      child: Text(
        'ISO $iso · $expMs · WB R$wbR/B$wbB',
        style: const TextStyle(color: Color(0xFF1D9E75), fontSize: 10),
      ),
    );
  }
}

enum CaptureState { searching, locked, capturing }

// ── Geometry overlay (unchanged) ──────────────────────────────────────────────

class GeometryOverlay extends StatelessWidget {
  final CaptureState state;
  final double pitchDeg;

  /// 'full' = full bbox + 5 ROI markers · 'small' = shrunken 65% box +
  /// center marker only · 'center' = center marker only.
  final String geomMode;

  /// A4 height guide: 0 = off, else target camera height in cm.
  final int guideCm;

  const GeometryOverlay(
      {super.key,
      required this.state,
      required this.pitchDeg,
      this.geomMode = 'full',
      this.guideCm = 0});

  /// Where an A4 sheet (portrait, centered on the C point) should appear
  /// at 45° tilt and 31 cm, as screen fractions: (centerY, bottomWidth,
  /// topWidth, height). BETA estimate derived from dataset geometry — to
  /// be CALIBRATED from the session-3 photos (paper + orange-tape quad at
  /// five ruler-verified heights).
  static const List<double> _paperGuide31 = [0.497, 0.55, 0.33, 0.33];

  /// Guide trapezoid for an arbitrary height: extents scale ~31/h
  /// (first-order; keystone change with height is ignored in this beta).
  static List<double> _paperGuideFor(int cm) {
    final r = 31.0 / cm;
    return [
      _paperGuide31[0],
      _paperGuide31[1] * r,
      _paperGuide31[2] * r,
      _paperGuide31[3] * r,
    ];
  }

  static const Map<String, Offset> _roiFractions = {
    'C':  Offset(0.495, 0.497),
    'UL': Offset(0.332, 0.336),
    'UR': Offset(0.665, 0.336),
    'LR': Offset(0.661, 0.667),
    'LL': Offset(0.332, 0.667),
  };

  Color get _frameColor => switch (state) {
    CaptureState.locked    => const Color(0xFF1D9E75),
    CaptureState.capturing => Colors.white,
    CaptureState.searching => Colors.white38,
  };

  String get _statusText => switch (state) {
    CaptureState.searching => 'Tilt phone to 45° · align surface in frame',
    CaptureState.locked    => 'Locked · place white paper · tap to capture',
    CaptureState.capturing => 'Capturing...',
  };

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // TRUE analysis region: tight bbox around the 4 corner ROIs in the
    // reference geometry (956..2107 x, 1308..2786 y on 3072x4080). Every
    // model analyzes THIS region (5x5 and 8x8 grids subdivide it), so it
    // must lie fully on the paper.
    // Full analysis region fractions; shrunken = 65% of it, centered.
    const shrink = 0.65;
    var frameL = size.width * 0.311;
    var frameT = size.height * 0.321;
    var frameW = size.width * 0.375;
    var frameH = size.height * 0.362;
    if (geomMode == 'small') {
      // Height-adaptive: the s8 extraction shrinks its box by 31/height
      // (constant physical footprint), so the DISPLAYED box must match —
      // what you see is what the model reads.
      final hf = guideCm > 0 ? 31.0 / guideCm : 1.0;
      final f = shrink * hf;
      frameL += frameW * (1 - f) / 2;
      frameT += frameH * (1 - f) / 2;
      frameW *= f;
      frameH *= f;
    }
    final showFrame = geomMode != 'center';
    final label = switch (geomMode) {
      'small'  => 'small analysis area — keep on paper',
      'center' => 'center patch only — any paper size',
      _        => 'analysis region — keep fully on paper',
    };

    return Stack(children: [
      if (showFrame)
        Positioned(
          left: frameL, top: frameT,
          child: Container(
            width: frameW, height: frameH,
            decoration: BoxDecoration(
              border: Border.all(color: _frameColor, width: 1.5),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      if (showFrame) ..._buildCorners(frameL, frameT, frameW, frameH),
      // ── A4 height guide (dashed amber trapezoid + label) ──────────────
      if (guideCm > 0) ...[
        Positioned.fill(
          child: CustomPaint(
            painter: _PaperGuidePainter(
                params: _paperGuideFor(guideCm),
                color: Colors.amber.withValues(alpha: 0.9)),
          ),
        ),
        Positioned(
          left: size.width * 0.25,
          top: size.height *
                  (_paperGuideFor(guideCm)[0] +
                      _paperGuideFor(guideCm)[3] / 2) +
              8,
          width: size.width * 0.5,
          child: Text(
            'A4 guide · $guideCm cm (beta) — match the sheet edges',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.amber, fontSize: 10),
          ),
        ),
      ],
      Positioned(
        left: size.width * 0.25,
        top: size.height * 0.321 + size.height * 0.362 + 6,
        width: size.width * 0.5,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
      ),
      if (state == CaptureState.locked) ..._buildRoiDots(size),
      Positioned(
        top: 52, right: 16,
        child: _AngleIndicator(pitchDeg: pitchDeg),
      ),
      Positioned(
        left: 16, right: 16, bottom: 120,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: state == CaptureState.locked
                    ? const Color(0xFF1D9E75) : Colors.amber,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(_statusText,
                style: const TextStyle(color: Colors.white, fontSize: 13))),
          ]),
        ),
      ),
    ]);
  }

  List<Widget> _buildRoiDots(Size size) {
    final entries = geomMode == 'full'
        ? _roiFractions.entries
        : _roiFractions.entries.where((e) => e.key == 'C');
    return entries.map((e) {
      final isCenter = e.key == 'C';
      final r = isCenter ? 14.0 : 10.0;
      final dx = e.value.dx * size.width;
      final dy = e.value.dy * size.height;
      return Positioned(
        left: dx - r, top: dy - r,
        child: Column(children: [
          Container(
            width: r * 2, height: r * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF1D9E75), width: 2),
            ),
          ),
          const SizedBox(height: 2),
          Text(e.key,
              style: const TextStyle(color: Colors.white70, fontSize: 9)),
        ]),
      );
    }).toList();
  }

  List<Widget> _buildCorners(double l, double t, double w, double h) {
    const len = 20.0; const thick = 2.0;
    Widget c(double left, double top, bool fh, bool fv) => Positioned(
      left: left, top: top,
      child: Transform.scale(scaleX: fh ? -1 : 1, scaleY: fv ? -1 : 1,
        child: SizedBox(width: len, height: len,
          child: CustomPaint(
            painter: _CornerPainter(color: _frameColor, thickness: thick)))),
    );
    return [
      c(l, t, false, false), c(l + w - len, t, true, false),
      c(l, t + h - len, false, true), c(l + w - len, t + h - len, true, true),
    ];
  }
}

class _AngleIndicator extends StatelessWidget {
  final double pitchDeg;
  const _AngleIndicator({required this.pitchDeg});
  bool get _isGood => pitchDeg >= 42 && pitchDeg <= 48;
  @override
  Widget build(BuildContext context) {
    final color = _isGood ? const Color(0xFF1D9E75) : Colors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.screen_rotation, size: 14, color: color),
        const SizedBox(width: 5),
        Text('${pitchDeg.toStringAsFixed(0)}°',
            style: TextStyle(color: color, fontSize: 13,
                fontWeight: FontWeight.w500)),
        const Text(' / 45°',
            style: TextStyle(color: Colors.white38, fontSize: 11)),
      ]),
    );
  }
}

/// Dashed trapezoid showing where the A4 sheet's edges should appear at
/// the target height (45° tilt keystones the far edge narrower).
class _PaperGuidePainter extends CustomPainter {
  final List<double> params; // [centerY, bottomWidth, topWidth, height]
  final Color color;
  const _PaperGuidePainter({required this.params, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = params[0] * size.height;
    final bw = params[1] * size.width;
    final tw = params[2] * size.width;
    final h = params[3] * size.height;
    final cx = size.width / 2;
    final path = Path()
      ..moveTo(cx - tw / 2, cy - h / 2)
      ..lineTo(cx + tw / 2, cy - h / 2)
      ..lineTo(cx + bw / 2, cy + h / 2)
      ..lineTo(cx - bw / 2, cy + h / 2)
      ..close();
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      const dash = 8.0, gap = 5.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), p);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_PaperGuidePainter o) =>
      o.params != params || o.color != color;
}

class _CornerPainter extends CustomPainter {
  final Color color; final double thickness;
  const _CornerPainter({required this.color, required this.thickness});
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color..strokeWidth = thickness
        ..strokeCap = StrokeCap.square..style = PaintingStyle.stroke;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), p);
    canvas.drawLine(Offset.zero, Offset(0, size.height), p);
  }
  @override
  bool shouldRepaint(_CornerPainter o) =>
      o.color != color || o.thickness != thickness;
}

// ── Model picker chip (single model or all) ───────────────────────────────────

class _ModelPickerChip extends StatelessWidget {
  final String selectedModel; // 'all' or a model name
  final ValueChanged<String> onModelSelected;
  const _ModelPickerChip(
      {required this.selectedModel, required this.onModelSelected});

  String get _displayName => switch (selectedModel) {
        'fast' => 'Fast (paper)',
        'grp_paper_all' => 'Paper + P&T suites',
        'grp_white' => 'White paper suite',
        'grp_plus' => 'Paper+table suite',
        'grp_table' => 'Table suite',
        'all' => 'All models',
        _ => null,
      } ??
      InferenceService.allModels
              .where((m) => m.name == selectedModel)
              .map((m) => m.displayName)
              .firstOrNull ??
          selectedModel;

  PopupMenuItem<String> _groupItem(
      String value, String title, String subtitle) {
    final sel = selectedModel == value;
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: [
        Icon(sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 18,
            color: sel ? const Color(0xFF1D9E75) : Colors.white38),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      color: sel ? const Color(0xFF1D9E75) : Colors.white,
                      fontSize: 14,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
              Text(subtitle,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: onModelSelected,
      color: const Color(0xFF1A1A1A),
      offset: const Offset(0, 40),
      itemBuilder: (_) {
        final items = <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: 'fast',
            child: Row(children: [
              Icon(
                  selectedModel == 'fast'
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selectedModel == 'fast'
                      ? const Color(0xFF1D9E75)
                      : Colors.white38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Fast (paper)',
                        style: TextStyle(
                            color: selectedModel == 'fast'
                                ? const Color(0xFF1D9E75)
                                : Colors.white,
                            fontSize: 14,
                            fontWeight: selectedModel == 'fast'
                                ? FontWeight.w600
                                : FontWeight.w400)),
                    const Text(
                        '8x8 paper lux + 250/500 lx thresholds — '
                        'recommended for field work',
                        style: TextStyle(
                            color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ),
            ]),
          ),
          PopupMenuItem<String>(
            value: 'all',
            child: Row(children: [
              Icon(
                  selectedModel == 'all'
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selectedModel == 'all'
                      ? const Color(0xFF1D9E75)
                      : Colors.white38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('All models',
                        style: TextStyle(
                            color: selectedModel == 'all'
                                ? const Color(0xFF1D9E75)
                                : Colors.white,
                            fontSize: 14,
                            fontWeight: selectedModel == 'all'
                                ? FontWeight.w600
                                : FontWeight.w400)),
                    Text(
                        'Run every model '
                        '(${InferenceService.allModels.length}) at once',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ),
            ]),
          ),
          _groupItem('grp_paper_all', 'Paper + paper&table suites',
              'All white-paper AND paper+table models — one capture '
              'feeds both contexts'),
          _groupItem('grp_white', 'White paper suite',
              'Only models trained on white paper'),
          _groupItem('grp_plus', 'Paper+table suite',
              'Only combined-surface models'),
          _groupItem('grp_table', 'Table suite',
              'Only bare-table models — calibrate separately on tables'),
          const PopupMenuDivider(),
        ];
        items.add(PopupMenuItem<String>(
          value: '__import__',
          child: Row(children: [
            const Icon(Icons.add_circle_outline,
                size: 18, color: Colors.white54),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Import model files...',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                  Text('Select the 3 files together: .onnx + '
                      '_features.txt + _meta.json',
                      style:
                          TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
          ]),
        ));
        items.add(const PopupMenuDivider());
        items.addAll(InferenceService.allModels.map((m) {
          final sel = m.name == selectedModel;
          return PopupMenuItem<String>(
            value: m.name,
            child: Row(children: [
              Icon(
                  sel
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: sel ? const Color(0xFF1D9E75) : Colors.white38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.displayName,
                        style: TextStyle(
                            color: sel
                                ? const Color(0xFF1D9E75)
                                : Colors.white,
                            fontSize: 14,
                            fontWeight:
                                sel ? FontWeight.w600 : FontWeight.w400)),
                    Text(m.description,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11)),
                  ],
                ),
              ),
            ]),
          );
        }));
        return items;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF1D9E75), width: 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.model_training,
              size: 14, color: Color(0xFF1D9E75)),
          const SizedBox(width: 5),
          Text(_displayName,
              style: const TextStyle(
                  color: Color(0xFF1D9E75),
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
          const SizedBox(width: 2),
          const Icon(Icons.arrow_drop_down,
              size: 16, color: Color(0xFF1D9E75)),
        ]),
      ),
    );
  }
}
