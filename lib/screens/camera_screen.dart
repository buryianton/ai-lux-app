import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';
import 'dart:math';

import '../services/inference_service.dart';
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

  bool get _isLocked => _pitchDeg >= 42 && _pitchDeg <= 48;

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

  Future<void> _capture() async {
    if (!_cameraReady || _state != CaptureState.locked) return;
    setState(() => _state = CaptureState.capturing);

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
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResultsScreen(
          imagePath: imagePath,
          source: source,
          run: run,
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
                  state: _state, pitchDeg: _pitchDeg, geomMode: _geomMode),
            ),

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
          IconButton(
            onPressed: _isRunningInference ? null : _pickAndAnalyze,
            icon: const Icon(Icons.photo_library_outlined,
                color: Colors.white70, size: 28),
            tooltip: 'Analyze photo from gallery',
          ),
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

  const GeometryOverlay(
      {super.key,
      required this.state,
      required this.pitchDeg,
      this.geomMode = 'full'});

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
      frameL += frameW * (1 - shrink) / 2;
      frameT += frameH * (1 - shrink) / 2;
      frameW *= shrink;
      frameH *= shrink;
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
