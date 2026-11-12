// lib/services/inference_service.dart
//
// Loads the captured JPEG, applies EXIF rotation, extracts the 5 ROI
// patches at the exact pixel coordinates used during training, computes
// the 110 handcrafted features in the same order as feature_master_latest.csv,
// and runs ONNX inference using onnxruntime.
//
// IMPORTANT: this must mirror the Python feature extraction pipeline
// EXACTLY (see Extra_tree.ipynb / feature_master_latest.csv generation):
//   - ROI sizes: C=256x256, UL/UR/LR/LL=128x128
//   - ROI pixel coords (post EXIF-transpose, full 3072x4080 image):
//       C:(1520,2027) UL:(1020,1372) UR:(2043,1372)
//       LR:(2030,2722) LL:(1020,2722)
//   - square context region = tight bbox around the 4 corner ROI boxes
//     (extra_margin = 0), subdivided into a 5x5 grid
//   - luma = 0.2126*R + 0.7152*G + 0.0722*B
//   - per ROI: mean_luma, std_luma, grad_mean, grad_std
//   - per grid cell: mean_luma, std_luma
//   - relational features (see _buildFeatureVector)

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

/// Reference geometry — pixel coordinates on the full, EXIF-corrected
/// image as captured on the reference device (Samsung Galaxy A16,
/// 3072x4080 portrait). All training photos used this exact geometry.
class RoiGeometry {
  static const int refWidth = 3072;
  static const int refHeight = 4080;

  // (x, y) center coordinates per ROI, in reference-image pixel space
  static const Map<String, Point<int>> centers = {
    'C':  Point(1520, 2027),
    'UL': Point(1020, 1372),
    'UR': Point(2043, 1372),
    'LR': Point(2030, 2722),
    'LL': Point(1020, 2722),
  };

  // ROI patch size (square side length) in reference-image pixel space
  static const Map<String, int> sizes = {
    'C':  256,
    'UL': 128,
    'UR': 128,
    'LR': 128,
    'LL': 128,
  };

  static const List<String> cornerOrder = ['UL', 'UR', 'LR', 'LL'];
  static const List<String> roiOrder = ['C', 'UL', 'UR', 'LR', 'LL'];
}

/// A simple per-region basic-feature bundle (mirrors compute_basic_features
/// reduced to the subset actually kept in feature_master_latest.csv).
class _BasicFeatures {
  final double meanR, meanG, meanB;
  final double meanLuma, stdLuma;
  final double gradMean, gradStd;
  final double meanSatProxy;

  _BasicFeatures({
    required this.meanR,
    required this.meanG,
    required this.meanB,
    required this.meanLuma,
    required this.stdLuma,
    required this.gradMean,
    required this.gradStd,
    required this.meanSatProxy,
  });
}

class ModelInfo {
  final String name;
  final String displayName;
  final String description;

  const ModelInfo({
    required this.name,
    required this.displayName,
    required this.description,
  });
}

class ModelBundle {
  final OrtSession session;
  final List<String> featureCols;
  final bool isLogSpace;
  final bool isClassifier;
  final bool isMulti; // multi-output regressor (5 ROI lux values)
  final bool isCnn;   // image-input CNN (shrunken-region grayscale)

  ModelBundle({
    required this.session,
    required this.featureCols,
    required this.isLogSpace,
    required this.isClassifier,
    this.isMulti = false,
    this.isCnn = false,
  });
}

class InferenceResult {
  /// lux estimate per ROI point (only populated for regression models)
  final Map<String, double>? luxByPoint;

  /// single overall lux estimate (center-point prediction)
  final double? luxEstimate;

  /// classifier outputs (only populated for classifier models)
  final int? classLabel;
  final double? classProbability;

  InferenceResult({
    this.luxByPoint,
    this.luxEstimate,
    this.classLabel,
    this.classProbability,
  });
}

/// Features extracted once from a single image (reusable across models).
class ExtractedFeatures {
  final Map<String, double> featureMap;
  final String imagePath;
  final int width, height;
  final Float32List? cnnInput; // 160x128 grayscale of shrunken region, /255
  ExtractedFeatures({
    required this.featureMap,
    required this.imagePath,
    required this.width,
    required this.height,
    this.cnnInput,
  });
}

/// Bundle returned by runAllModels: the shared features + per-model results.
class AllModelsRun {
  final ExtractedFeatures extracted;
  final Map<String, InferenceResult> results;
  AllModelsRun({required this.extracted, required this.results});
}

class InferenceService {
  static final Map<String, ModelBundle> _cache = {};

  /// Registry of available models for the picker UI.
  /// To add a new model: drop {name}.onnx, {name}_features.txt, and
  /// {name}_meta.json into assets/models/, then add one entry here.
  /// Phone identity ("samsung SM-A166U1"), set at startup from the
  /// native side; stamped into logs and calibration by their services.
  static String deviceModel = '';

  // ── Custom (user-imported) models ──────────────────────────────────
  static final List<ModelInfo> _customModels = [];
  static final Map<String, String> _customDirOf = {}; // name -> dir
  static List<ModelInfo> get customModels =>
      List.unmodifiable(_customModels);

  /// Built-in + imported models. Suites match by name, so customs join
  /// their groups automatically.
  static List<ModelInfo> get allModels =>
      [...availableModels, ..._customModels];

  /// Scans [dirPath] for model trios (x.onnx + x_features.txt +
  /// x_meta.json) and registers complete ones. Returns the count.
  static Future<int> refreshCustomModels(String dirPath) async {
    _customModels.clear();
    _customDirOf.clear();
    final dir = Directory(dirPath);
    if (!await dir.exists()) return 0;
    final names = (await dir.list().toList())
        .whereType<File>()
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .toSet();
    for (final f in names) {
      if (!f.endsWith('.onnx')) continue;
      final base = f.substring(0, f.length - 5);
      if (!names.contains('${base}_features.txt') ||
          !names.contains('${base}_meta.json')) continue;
      if (availableModels.any((m) => m.name == base)) continue;
      String display = base, desc = 'Imported model';
      try {
        final meta = jsonDecode(await File(
                '$dirPath${Platform.pathSeparator}${base}_meta.json')
            .readAsString()) as Map<String, dynamic>;
        display = (meta['display_name'] as String?) ?? base;
        desc = (meta['description'] as String?) ?? desc;
      } catch (_) {}
      _customModels.add(ModelInfo(
          name: base, displayName: '$display (imported)', description: desc));
      _customDirOf[base] = dirPath;
      _cache.remove(base);
    }
    return _customModels.length;
  }

  static Future<Uint8List> _readModelBytes(String name, String suffix) async {
    final dir = _customDirOf[name];
    if (dir != null) {
      return File('$dir${Platform.pathSeparator}$name$suffix').readAsBytes();
    }
    final d = await rootBundle.load('assets/models/$name$suffix');
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }

  static Future<String> _readModelText(String name, String suffix) async {
    final dir = _customDirOf[name];
    if (dir != null) {
      return File('$dir${Platform.pathSeparator}$name$suffix').readAsString();
    }
    return rootBundle.loadString('assets/models/$name$suffix');
  }

  static const List<ModelInfo> availableModels = [
    ModelInfo(
      name: 'et_white',
      displayName: 'White paper',
      description: 'Regression · trained on white paper only',
    ),
    ModelInfo(
      name: 'et_table',
      displayName: 'Table surface',
      description: 'Regression · trained on table surfaces only',
    ),
    // RETIRED after field evaluation (2026-07, n=90):
    //  - et_white_plus: 10.3% calibrated, dominated by et_s8/v2b_white_plus
    //  - clf_combo_200lux: 80% on native capture, all errors false-
    //    compliance in dim rooms (48-130 lx read as >=200) — the unsafe
    //    direction. Files remain in assets; deregistered from roster.
    // ModelInfo(name: 'et_white_plus', ...),
    // ModelInfo(name: 'clf_combo_200lux', ...),
    ModelInfo(
      name: 'clf_white_500lux',
      displayName: '500 lux check',
      description: 'Classifier · pass/fail at 500 lux (white paper)',
    ),
    ModelInfo(
      name: 'et_multi5_white_paper',
      displayName: '5-point map (paper)',
      description: 'Regression · lux at all 5 ROIs + uniformity · '
          'values drawn on the photo',
    ),
    ModelInfo(
      name: 'et_s8_white_paper',
      displayName: 'Small area (paper)',
      description: 'Regression · shrunken 65% grid, always fits A4 · '
          'robust to paper placement',
    ),
    ModelInfo(
      name: 'et_s8_table',
      displayName: 'Small area (table)',
      description: 'Regression · shrunken 65% grid on bare tables · '
          'experimental',
    ),
    ModelInfo(
      name: 'et_s8_white_plus',
      displayName: 'Small area (paper+table)',
      description: 'Regression · shrunken 65% grid, combined surfaces',
    ),
    ModelInfo(
      name: 'cnn_s8_white_paper',
      displayName: 'CNN (paper, experimental)',
      description: 'Deep learning · raw pixels of the small area · '
          'for research comparison',
    ),
    ModelInfo(
      name: 'cnn_s8_white_plus',
      displayName: 'CNN (paper+table, experimental)',
      description: 'Deep learning · raw pixels of the small area, '
          'combined surfaces · for research comparison',
    ),
    ModelInfo(
      name: 'clf_s8_white_paper_250lux',
      displayName: '250 lux check (paper, small area)',
      description: 'Threshold · is illuminance above 250 lx · '
          'A4-safe geometry',
    ),
    ModelInfo(
      name: 'clf_s8_white_paper_500lux',
      displayName: '500 lux check (paper, small area)',
      description: 'Threshold · is illuminance above 500 lx · '
          'A4-safe geometry',
    ),
    ModelInfo(
      name: 'clf_s8_white_plus_250lux',
      displayName: '250 lux check (paper+table, small area)',
      description: 'Threshold · combined surfaces · A4-safe geometry',
    ),
    ModelInfo(
      name: 'clf_s8_white_plus_500lux',
      displayName: '500 lux check (paper+table, small area)',
      description: 'Threshold · combined surfaces · A4-safe geometry',
    ),
    ModelInfo(
      name: 'clf_s8_table_250lux',
      displayName: '250 lux check (table, small area)',
      description: 'Threshold · bare tables · experimental',
    ),
    ModelInfo(
      name: 'clf_s8_table_500lux',
      displayName: '500 lux check (table, small area)',
      description: 'Threshold · bare tables · experimental',
    ),
    ModelInfo(
      name: 'et_c1_white_paper',
      displayName: 'Center only (paper)',
      description: 'Regression · central patch only · immune to paper '
          'size and placement',
    ),
    ModelInfo(
      name: 'et_c1_table',
      displayName: 'Center only (table)',
      description: 'Regression · central patch on bare tables · '
          'experimental, high uncertainty',
    ),
    ModelInfo(
      name: 'et_c1_white_plus',
      displayName: 'Center only (paper+table)',
      description: 'Regression · central patch, combined surfaces',
    ),
    // ── Variant 2b: central ROI + 8x8 gridded square context ──────────────
    // Fits on a single sheet of paper; matches or beats the original
    // 5-corner-ROI design, especially on table surfaces.
    ModelInfo(
      name: 'et_v2b_white_paper',
      displayName: 'White paper (8×8 grid)',
      description: 'Regression · single-sheet geometry · MAPE 4.04%',
    ),
    ModelInfo(
      name: 'et_v2b_table',
      displayName: 'Table (8×8 grid)',
      description: 'Regression · single-sheet geometry · MAPE 5.08%',
    ),
    ModelInfo(
      name: 'et_v2b_white_plus',
      displayName: 'White + table (8×8 grid)',
      description: 'Regression · single-sheet geometry · MAPE 5.22%',
    ),
    ModelInfo(
      name: 'clf8x8_white_paper_250lux',
      displayName: '250 lux check (paper, 8×8)',
      description: 'Classifier · pass/fail at 250 lux · white paper',
    ),
    ModelInfo(
      name: 'clf8x8_white_paper_500lux',
      displayName: '500 lux check (paper, 8×8)',
      description: 'Classifier · pass/fail at 500 lux · white paper',
    ),
    ModelInfo(
      name: 'clf8x8_table_250lux',
      displayName: '250 lux check (table, 8×8)',
      description: 'Classifier · pass/fail at 250 lux · table',
    ),
    ModelInfo(
      name: 'clf8x8_table_500lux',
      displayName: '500 lux check (table, 8×8)',
      description: 'Classifier · pass/fail at 500 lux · table',
    ),
    ModelInfo(
      name: 'clf8x8_white_plus_250lux',
      displayName: '250 lux check (combo, 8×8)',
      description: 'Classifier · pass/fail at 250 lux · white+table',
    ),
    ModelInfo(
      name: 'clf8x8_white_plus_500lux',
      displayName: '500 lux check (combo, 8×8)',
      description: 'Classifier · pass/fail at 500 lux · white+table',
    ),
  ];

  /// Call once at app startup (e.g. in main()) so the ONNX env is ready.
  static void init() {
    OrtEnv.instance.init();
  }

  static void dispose() {
    for (final bundle in _cache.values) {
      bundle.session.release();
    }
    _cache.clear();
    OrtEnv.instance.release();
  }

  /// Loads (and caches) a model bundle by name, e.g. 'et_white',
  /// 'et_table', 'et_white_plus', 'clf_combo_200lux', 'clf_white_500lux'.
  static Future<ModelBundle> loadModel(String name) async {
    if (_cache.containsKey(name)) return _cache[name]!;

    // Load ONNX bytes (bundled asset or imported custom model)
    final bytes = await _readModelBytes(name, '.onnx');

    final sessionOptions = OrtSessionOptions();
    final session = OrtSession.fromBuffer(bytes, sessionOptions);

    // Load feature column order
    final featuresText = await _readModelText(name, '_features.txt');
    final featureCols = featuresText
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    // Load metadata (is_log_space / is_classifier)
    final metaText = await _readModelText(name, '_meta.json');
    final isLog = metaText.contains('"is_log_space": true') ||
        metaText.contains('"is_log_space":true');
    final isClf = metaText.contains('"is_classifier": true') ||
        metaText.contains('"is_classifier":true');
    final isMulti = metaText.contains('"multi_regressor"');
    final isCnn = metaText.contains('"cnn_regressor"');

    final bundle = ModelBundle(
      session: session,
      featureCols: featureCols,
      isLogSpace: isLog,
      isClassifier: isClf,
      isMulti: isMulti,
      isCnn: isCnn,
    );
    _cache[name] = bundle;
    return bundle;
  }

  /// Quick field preset: primary regressor + the two compliance
  /// thresholds. Runs ~5x fewer models than 'all'.
  static const fastPreset = [
    // Pure paper protocol, A4-safe geometry: one estimate, two checks.
    // (P+T models excluded: redundant on paper, and their capture-path
    // classifiers mislead; full-geometry models excluded: A4 placement
    // cannot be guaranteed.)
    'et_s8_white_paper',
    'clf_s8_white_paper_250lux',
    'clf_s8_white_paper_500lux',
  ];

  /// ── Model groups ─────────────────────────────────────────────────
  /// Suites for context-specific testing: calibrate and measure with the
  /// group that matches the surface protocol in use.
  static List<String> _byRule(bool Function(String) rule) => [
        for (final m in allModels)
          if (rule(m.name)) m.name
      ];

  static List<String> get whitePaperSuite => _byRule((n) =>
      n.contains('white_paper') || n.startsWith('clf_white_'));

  static List<String> get whitePlusSuite => _byRule(
      (n) => n.contains('white_plus') || n.contains('combo'));

  static List<String> get tableSuite => _byRule((n) => n.contains('_table'));

  /// Combined suite: every white-paper model AND every paper+table
  /// model — one capture feeds both contexts (calibration efficiency).
  static List<String> get paperAllSuite =>
      {...whitePaperSuite, ...whitePlusSuite}.toList();

  /// Resolves a picker selection to the model list for runAllModels.
  /// Returns null for 'all' (= every model) and for single-model names.
  static List<String>? modelsForSelection(String sel) => switch (sel) {
        'fast' => fastPreset,
        'grp_paper_all' => paperAllSuite,
        'grp_white' => whitePaperSuite,
        'grp_plus' => whitePlusSuite,
        'grp_table' => tableSuite,
        _ => null,
      };

  /// Set true only when re-running the Dart/Python parity check —
  /// writes <name>_features.json next to each processed image.
  static bool enableParityDump = false;

  // ── Pipeline correction: Camera2-JPEG -> stock-JPEG (dataset) domain ──
  // The two pipelines differ by CHANNEL MIXING (Samsung stock applies a
  // scene-adaptive color matrix), so a 1-D luma LUT is CCT-dependent and
  // was replaced (2026-09-23) by a two-band affine 3x3 color transform
  // fitted on 111 paired captures at 2700/5000/6500 K (median luma
  // residual 2.7%, CCT-independent — and being linear, it is also correct
  // under MIXED illuminants). Bands split at luma ~96 with a smooth blend
  // so gradient features see no seam. Native captures only — uploads are
  // already stock JPEGs.
  static bool pipelineLutEnabled = true;
  static bool _lutActive = false; // set per-extraction (isolate-local)

  // app [r,g,b,1] -> stock [r,g,b]; column-major per output channel.
  // v2 (2026-09-24): refit on 167 pairs across TWO physical lamps,
  // 2700/4000/5000/6500 K and two mixed-illuminant setups; median pixel
  // residual 2.64%, all lamp groups within +-3.3%. Leave-one-lamp-out
  // showed an unseen lamp costs ~-6% dark — so per-device fits should
  // always include at least two different lamps.
  static const List<List<double>> _mLow = [
    [1.60738, -0.10180, -0.61545, 6.40637], // stock R coeffs
    [-0.38929, 1.44052, -0.25916, -0.32679], // stock G
    [-0.70604, 0.25279, 1.95878, 12.45643], // stock B
  ];
  static const List<List<double>> _mHigh = [
    [1.50713, -0.17004, -0.40227, -7.59821],
    [-0.19337, 1.12709, -0.00495, -20.25705],
    [-0.59383, -0.00791, 1.65860, 34.75984],
  ];

  // Residual tone curve (applied AFTER the color matrix, to the Fast
  // primary regressor's output on the capture path). Fitted 2026-09-30 on
  // 25 centered captures across 2700-6500 K: removes the S-shaped
  // luma-dependent residual the two coarse matrix bands cannot bend
  // around (-10..-14% dark, +8..+17% around 450-560 lx; MAPE 7.4% -> 2.8%,
  // one curve for all CCTs).
  static const List<double> _toneX = [70, 293, 455, 582, 663];
  static const List<double> _toneY = [0.8877, 0.9404, 1.0538, 1.1028, 1.0120];

  static double _toneCorrect(double lux) {
    double r;
    if (lux <= _toneX.first) {
      r = _toneY.first;
    } else if (lux >= _toneX.last) {
      r = _toneY.last;
    } else {
      r = _toneY.last;
      for (var i = 1; i < _toneX.length; i++) {
        if (lux <= _toneX[i]) {
          final t = (lux - _toneX[i - 1]) / (_toneX[i] - _toneX[i - 1]);
          r = _toneY[i - 1] + t * (_toneY[i] - _toneY[i - 1]);
          break;
        }
      }
    }
    return lux / r;
  }

  /// Applies the two-band pipeline color correction to one pixel.
  /// Returns [r, g, b] in the stock/dataset domain, clamped to 0..255.
  static List<double> _pipeCorrect(double r, double g, double b) {
    final luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    // blend weight: 0 = low matrix (luma<=80), 1 = high (luma>=112)
    final w = ((luma - 80.0) / 32.0).clamp(0.0, 1.0);
    final out = List<double>.filled(3, 0);
    for (var c = 0; c < 3; c++) {
      final lo = _mLow[c][0] * r + _mLow[c][1] * g +
          _mLow[c][2] * b + _mLow[c][3];
      final hi = _mHigh[c][0] * r + _mHigh[c][1] * g +
          _mHigh[c][2] * b + _mHigh[c][3];
      out[c] = ((1 - w) * lo + w * hi).clamp(0.0, 255.0);
    }
    return out;
  }

  /// Full pipeline: read JPEG -> EXIF transpose -> extract ROI features
  /// -> run inference with the given model -> return result.
  static Future<InferenceResult> runInference({
    required String imagePath,
    required String modelName,
    double heightCm = 31.0,
    bool pipelineLut = false,
  }) async {
    // Heavy image work (decode + features) runs in a background isolate
    // so the UI thread never blocks long enough to trigger an ANR.
    final extracted = await Isolate.run(() => extractFeatures(imagePath,
        heightCm: heightCm, pipelineLut: pipelineLut));
    return runOnFeatures(
        modelName: modelName,
        featureMap: extracted.featureMap,
        cnnInput: extracted.cnnInput);
  }

  /// Runs models on a single image, extracting features only once.
  /// By default runs EVERY model in [availableModels]; pass [onlyModel]
  /// to run just one. Returns modelName -> result.
  static Future<AllModelsRun> runAllModels(String imagePath,
      {String? onlyModel,
      List<String>? models,
      double heightCm = 31.0,
      bool pipelineLut = false}) async {
    // Heavy image work in a background isolate (ANR guard).
    final extracted = await Isolate.run(() => extractFeatures(imagePath,
        heightCm: heightCm, pipelineLut: pipelineLut));
    final selected = models != null
        ? allModels.where((m) => models.contains(m.name)).toList()
        : onlyModel == null
            ? allModels
            : allModels.where((m) => m.name == onlyModel).toList();
    final results = <String, InferenceResult>{};
    for (final m in selected) {
      // Yield to the UI between models so first-time asset loading of
      // many large ONNX files can't starve the main thread.
      await Future<void>.delayed(Duration.zero);
      try {
        results[m.name] = await runOnFeatures(
            modelName: m.name,
            featureMap: extracted.featureMap,
            cnnInput: extracted.cnnInput);
      } catch (e) {
        // One broken model must not kill the batch.
        // ignore: avoid_print
        print('Model ${m.name} failed: $e');
      }
    }
    // Residual tone curve on the Fast primary (capture path only).
    if (pipelineLut && pipelineLutEnabled) {
      final r = results['et_s8_white_paper'];
      if (r?.luxEstimate != null) {
        results['et_s8_white_paper'] =
            InferenceResult(luxEstimate: _toneCorrect(r!.luxEstimate!));
      }
    }
    return AllModelsRun(extracted: extracted, results: results);
  }

  /// Steps 1-5: decode, EXIF-correct, extract the full named feature map.
  ///
  /// [heightCm]: camera height above the surface. The shrunken (s8)
  /// context box is scaled by 31/height so it keeps a CONSTANT PHYSICAL
  /// footprint on the paper at any height, then resized back to the
  /// reference pixel size so texture/gradient features keep the training
  /// pixel scale. Validated on frozen-lamp sweeps (2026-09-22): raw bias
  /// flat within ~1.5 pp across 31-56 cm (vs -9.7% drift when fixed).
  static Future<ExtractedFeatures> extractFeatures(String imagePath,
      {double heightCm = 31.0, bool pipelineLut = false}) async {
    _lutActive = pipelineLut && pipelineLutEnabled;
    // ── 1. Load + EXIF-transpose the image ────────────────────────────
    final bytes = await File(imagePath).readAsBytes();
    img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('Could not decode image at $imagePath');
    }
    // bakeOrientation reads EXIF orientation tag and physically rotates
    // pixels to match — equivalent to PIL's ImageOps.exif_transpose().
    img.Image image = img.bakeOrientation(decoded);

    // Safety net: training geometry is portrait (3072x4080). If the image
    // is still landscape after EXIF baking (e.g. a JPEG written without an
    // orientation tag), rotate 90° so ROIs land where they should.
    if (image.width > image.height) {
      // ignore: avoid_print
      print('WARNING: landscape image after EXIF bake — rotating 90°');
      image = img.copyRotate(image, angle: 90);
    }

    // ── 2. Scale ROI geometry to actual captured image size ───────────
    // Reference geometry was defined on a 3072x4080 image. If the
    // device/camera produces a different resolution, scale proportionally.
    final scaleX = image.width / RoiGeometry.refWidth;
    final scaleY = image.height / RoiGeometry.refHeight;

    final Map<String, Point<int>> centers = {
      for (final entry in RoiGeometry.centers.entries)
        entry.key: Point(
          (entry.value.x * scaleX).round(),
          (entry.value.y * scaleY).round(),
        ),
    };
    final Map<String, int> sizes = {
      for (final entry in RoiGeometry.sizes.entries)
        entry.key: ((entry.value * ((scaleX + scaleY) / 2)).round()),
    };

    // ── 3. Extract per-ROI basic features ──────────────────────────────
    final Map<String, _BasicFeatures> roiFeats = {};
    for (final roi in RoiGeometry.roiOrder) {
      final c = centers[roi]!;
      final s = sizes[roi]!;
      final patch = _cropPatch(image, c.x, c.y, s);
      roiFeats[roi] = _computeBasicFeatures(patch);
    }

    // ── 4. Square context region (tight bbox around 4 corner ROIs) ────
    final cornerBox = _tightBboxFromCorners(centers, sizes);
    final squarePatch = _cropBbox(
      image,
      cornerBox.left,
      cornerBox.top,
      cornerBox.right,
      cornerBox.bottom,
    );
    final squareBasic = _computeBasicFeatures(squarePatch);
    final gridFeats5x5 = _computeGridFeatures(squarePatch, gridN: 5, prefix: 'square');
    final gridFeats8x8 = _computeGridFeatures(squarePatch, gridN: 8, prefix: 'sq8');

    // ── 4b. SHRUNKEN context (65% of the bbox, centered) ──────────────
    // Guaranteed to lie on an A4 sheet even with sloppy placement.
    // Feature names must match the Colab extractor (prefix sqs8_).
    const shrink = 0.65;
    final scx = (cornerBox.left + cornerBox.right) / 2;
    final scy = (cornerBox.top + cornerBox.bottom) / 2;
    final shw = (cornerBox.right - cornerBox.left) / 2 * shrink;
    final shh = (cornerBox.bottom - cornerBox.top) / 2 * shrink;
    // Height-adaptive sampling: constant physical footprint (see docstring).
    final hf = 31.0 / heightCm;
    final shrunkRaw = _cropBbox(
      image,
      (scx - shw * hf).round(),
      (scy - shh * hf).round(),
      (scx + shw * hf).round(),
      (scy + shh * hf).round(),
    );
    final shrunkPatch = (hf - 1.0).abs() < 1e-6
        ? shrunkRaw
        : img.copyResize(shrunkRaw,
            width: (2 * shw).round(), height: (2 * shh).round());
    final shrunkBasic = _computeBasicFeatures(shrunkPatch);
    final gridShrunk = _computeGridFeatures(shrunkPatch, gridN: 8, prefix: 'sqs8');
    gridShrunk['sqs8_mean_luma'] = shrunkBasic.meanLuma;
    gridShrunk['sqs8_std_luma'] = shrunkBasic.stdLuma;
    gridShrunk['sqs8_grad_mean'] = shrunkBasic.gradMean;
    gridShrunk['sqs8_grad_std'] = shrunkBasic.gradStd;

    // Prepared CNN input: shrunken patch -> 128x160 -> luma/255 (NHWC).
    final cnnResized =
        img.copyResize(shrunkPatch, width: 128, height: 160);
    final cnnInput = Float32List(160 * 128);
    var ci = 0;
    for (var yy = 0; yy < 160; yy++) {
      for (var xx = 0; xx < 128; xx++) {
        final px = cnnResized.getPixel(xx, yy);
        var r = px.r.toDouble(), g = px.g.toDouble(), b = px.b.toDouble();
        if (_lutActive) {
          final c = _pipeCorrect(r, g, b);
          r = c[0];
          g = c[1];
          b = c[2];
        }
        cnnInput[ci++] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
      }
    }

    final gridFeats = <String, dynamic>{
      ...gridFeats5x5, ...gridFeats8x8, ...gridShrunk};

    // ── 5. Build the named feature map exactly matching training ──────
    final featureMap = _buildFeatureMap(roiFeats, squareBasic, gridFeats);
    featureMap.addAll(_buildCoordFeatureMap(centers));

    // ── Optional parity dump (see enableParityDump) ────────────────────
    if (enableParityDump) {
      try {
        final dumpFile = File(imagePath.replaceAll(
            RegExp(r'\.(jpg|jpeg)$', caseSensitive: false),
            '_features.json'));
        await dumpFile.writeAsString(jsonEncode({
          'image': imagePath.split(Platform.pathSeparator).last,
          'decoded_w': image.width,
          'decoded_h': image.height,
          'scaleX': scaleX,
          'scaleY': scaleY,
          'features': featureMap,
        }));
      } catch (e) {
        // ignore: avoid_print
        print('Feature dump failed: $e');
      }
    }

    return ExtractedFeatures(
      featureMap: featureMap,
      imagePath: imagePath,
      width: image.width,
      height: image.height,
      cnnInput: cnnInput,
    );
  }

  /// Steps 6-7: assemble the model's input vector and run ONNX inference.
  static Future<InferenceResult> runOnFeatures({
    required String modelName,
    required Map<String, double> featureMap,
    Float32List? cnnInput,
  }) async {
    final bundle = await loadModel(modelName);

    if (bundle.isCnn) {
      if (cnnInput == null) {
        throw Exception('CNN model requires image input');
      }
      final tensor = OrtValueTensor.createTensorWithDataList(
          cnnInput, [1, 160, 128, 1]);
      final outputs = bundle.session.run(
          OrtRunOptions(), {'input_image': tensor});
      tensor.release();
      final v = outputs[0]?.value;
      double raw = 0.0;
      if (v is List && v.isNotEmpty) {
        final f = v.first;
        raw = f is List ? (f.first as num).toDouble() : (f as num).toDouble();
      }
      for (final o in outputs) { o?.release(); }
      final lux = bundle.isLogSpace ? (exp(raw) - 1.0) : raw;
      return InferenceResult(luxEstimate: lux);
    }

    // ── 6. Assemble feature vector in the model's expected column order
    final inputVec = Float32List(bundle.featureCols.length);
    for (var i = 0; i < bundle.featureCols.length; i++) {
      final col = bundle.featureCols[i];
      final v = featureMap[col];
      if (v == null) {
        throw Exception('Missing feature "$col" — check feature mapping');
      }
      inputVec[i] = v;
    }

    // ── 7. Run ONNX inference ──────────────────────────────────────────
    final shape = [1, inputVec.length];
    final inputOrt = OrtValueTensor.createTensorWithDataList(inputVec, shape);
    final inputs = {'float_input': inputOrt};

    final runOptions = OrtRunOptions();
    final outputs = await bundle.session.runAsync(runOptions, inputs);
    inputOrt.release();
    runOptions.release();

    if (bundle.isClassifier) {
      // After re-export with zipmap=False, ONNX output format is:
      //   outputs[0] = 'label'         -> int64, shape [N]
      //   outputs[1] = 'probabilities' -> float tensor, shape [N, 2]
      // (previously this was a broken seq(map(int64,tensor(float)))
      // format that the Flutter onnxruntime package could not parse —
      // zipmap=False avoids that entirely.)
      final labelTensor = outputs?[0]?.value;
      int label = 0;
      if (labelTensor is List) {
        label = (labelTensor.first as num).toInt();
      }

      double prob = 0.0;
      final probaRaw = outputs?[1]?.value;
      try {
        if (probaRaw is List && probaRaw.isNotEmpty) {
          final first = probaRaw.first;
          if (first is List && first.length > 1) {
            // [ [p0, p1] ] -> take p1 (probability of class 1)
            prob = (first[1] as num).toDouble();
          } else if (first is num) {
            // Flat [p0, p1] for a single sample
            prob = (probaRaw.length > 1
                    ? (probaRaw[1] as num)
                    : (first))
                .toDouble();
          }
        }
      } catch (_) {
        prob = label.toDouble();
      }

      for (final o in outputs ?? []) {
        o?.release();
      }

      return InferenceResult(classLabel: label, classProbability: prob);
    } else {
      final outTensor = outputs?[0]?.value;
      var vals = <double>[];
      if (outTensor is List && outTensor.isNotEmpty) {
        final first = outTensor.first;
        if (first is List) {
          // nested form: [[v0, v1, ...]]
          vals = [for (final v in first) (v as num).toDouble()];
        } else {
          // flat form: [v0, v1, ...] — take ALL values (a multi-output
          // model's 5 targets arrive flattened in this runtime version)
          vals = [for (final v in outTensor) (v as num).toDouble()];
        }
      }
      for (final o in outputs ?? []) {
        o?.release();
      }

      double toLux(double r) => bundle.isLogSpace ? (exp(r) - 1.0) : r;

      if (bundle.isMulti) {
        // DIAGNOSTIC — remove once multi5 is confirmed working:
        // ignore: avoid_print
        print('multi5 DEBUG: outTensor=${outTensor.runtimeType} '
            'parsed=${vals.length} values=$vals');
      }

      if (bundle.isMulti && vals.length >= 5) {
        // Target order fixed at training: lux_C, lux_UL, lux_UR,
        // lux_LR, lux_LL (see et_multi5_*_meta.json).
        const pts = ['C', 'UL', 'UR', 'LR', 'LL'];
        final byPoint = <String, double>{
          for (var i = 0; i < 5; i++) pts[i]: toLux(vals[i])
        };
        return InferenceResult(
            luxByPoint: byPoint, luxEstimate: byPoint['C']);
      }

      final lux = toLux(vals.isNotEmpty ? vals.first : 0.0);
      return InferenceResult(luxEstimate: lux);
    }
  }

  // ── Image helpers ──────────────────────────────────────────────────

  /// Crop a square patch of [size] centered at ([cx], [cy]), with
  /// edge-padding if the patch would extend past image bounds
  /// (mirrors numpy's mode="edge" padding used in training).
  static img.Image _cropPatch(img.Image image, int cx, int cy, int size) {
    final half = size ~/ 2;
    final left = cx - half;
    final top = cy - half;
    final right = left + size;
    final bottom = top + size;
    return _cropBbox(image, left, top, right, bottom);
  }

  static img.Image _cropBbox(
      img.Image image, int left, int top, int right, int bottom) {
    final w = right - left;
    final h = bottom - top;

    // Build an output buffer, sampling source pixels with edge clamping
    // — equivalent to np.pad(..., mode="edge") followed by crop.
    final out = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      final srcY = (top + y).clamp(0, image.height - 1);
      for (var x = 0; x < w; x++) {
        final srcX = (left + x).clamp(0, image.width - 1);
        out.setPixel(x, y, image.getPixel(srcX, srcY));
      }
    }
    return out;
  }

  static ({int left, int top, int right, int bottom}) _tightBboxFromCorners(
    Map<String, Point<int>> centers,
    Map<String, int> sizes,
  ) {
    final lefts = <int>[], rights = <int>[], tops = <int>[], bottoms = <int>[];
    for (final roi in RoiGeometry.cornerOrder) {
      final c = centers[roi]!;
      final r = sizes[roi]! ~/ 2;
      lefts.add(c.x - r);
      rights.add(c.x + r);
      tops.add(c.y - r);
      bottoms.add(c.y + r);
    }
    return (
      left: lefts.reduce(min),
      right: rights.reduce(max),
      top: tops.reduce(min),
      bottom: bottoms.reduce(max),
    );
  }

  /// Computes mean_r/g/b, mean_luma, std_luma, grad_mean, grad_std,
  /// mean_sat_proxy for a patch — mirrors compute_basic_features_from_array.
  static _BasicFeatures _computeBasicFeatures(img.Image patch) {
    final w = patch.width, h = patch.height;
    final n = w * h;

    final luma = Float32List(n);
    double sumR = 0, sumG = 0, sumB = 0, sumSat = 0;

    var idx = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = patch.getPixel(x, y);
        var r = p.r.toDouble();
        var g = p.g.toDouble();
        var b = p.b.toDouble();
        // Pipeline correction: map native-capture pixels into the
        // stock/dataset color domain before any feature is computed.
        if (_lutActive) {
          final c = _pipeCorrect(r, g, b);
          r = c[0];
          g = c[1];
          b = c[2];
        }
        sumR += r;
        sumG += g;
        sumB += b;

        luma[idx] = 0.2126 * r + 0.7152 * g + 0.0722 * b;

        final maxC = max(r, max(g, b));
        final minC = min(r, min(g, b));
        final rgbSum = r + g + b + 1e-8;
        sumSat += (maxC - minC) / rgbSum;

        idx++;
      }
    }

    final meanR = sumR / n;
    final meanG = sumG / n;
    final meanB = sumB / n;
    final meanSat = sumSat / n;

    double meanLuma = 0;
    for (final l in luma) {
      meanLuma += l;
    }
    meanLuma /= n;

    double varLuma = 0;
    for (final l in luma) {
      final d = l - meanLuma;
      varLuma += d * d;
    }
    varLuma /= n;
    final stdLuma = sqrt(varLuma);

    // gradient magnitude via central differences (mirrors np.gradient)
    double sumGrad = 0, sumGradSq = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final gx = _gradAt(luma, w, h, x, y, dx: true);
        final gy = _gradAt(luma, w, h, x, y, dx: false);
        final mag = sqrt(gx * gx + gy * gy);
        sumGrad += mag;
        sumGradSq += mag * mag;
      }
    }
    final gradMean = sumGrad / n;
    final gradVar = (sumGradSq / n) - (gradMean * gradMean);
    final gradStd = sqrt(gradVar < 0 ? 0 : gradVar);

    return _BasicFeatures(
      meanR: meanR,
      meanG: meanG,
      meanB: meanB,
      meanLuma: meanLuma,
      stdLuma: stdLuma,
      gradMean: gradMean,
      gradStd: gradStd,
      meanSatProxy: meanSat,
    );
  }

  /// Central-difference gradient at (x,y), matching numpy.gradient's
  /// edge handling (forward/backward diff at boundaries).
  static double _gradAt(
    Float32List luma,
    int w,
    int h,
    int x,
    int y, {
    required bool dx,
  }) {
    double at(int xx, int yy) => luma[yy * w + xx];

    if (dx) {
      if (w == 1) return 0.0;
      if (x == 0) return at(1, y) - at(0, y);
      if (x == w - 1) return at(w - 1, y) - at(w - 2, y);
      return (at(x + 1, y) - at(x - 1, y)) / 2.0;
    } else {
      if (h == 1) return 0.0;
      if (y == 0) return at(x, 1) - at(x, 0);
      if (y == h - 1) return at(x, h - 1) - at(x, h - 2);
      return (at(x, y + 1) - at(x, y - 1)) / 2.0;
    }
  }

  /// Computes the 5x5 grid cell features (mean_luma, std_luma only —
  /// matching what was retained in feature_master_latest.csv) plus the
  /// relational summary features (top/bottom/left/right/center/corner,
  /// range, std).
  static Map<String, dynamic> _computeGridFeatures(
    img.Image squarePatch, {
    required int gridN,
    String prefix = 'square',
  }) {
    final w = squarePatch.width, h = squarePatch.height;
    final rows = List<int>.generate(
        gridN + 1, (i) => (h * i / gridN).round());
    final cols = List<int>.generate(
        gridN + 1, (i) => (w * i / gridN).round());

    final cellMeans = List.generate(gridN, (_) => List.filled(gridN, 0.0));
    final cellStds = List.generate(gridN, (_) => List.filled(gridN, 0.0));

    for (var i = 0; i < gridN; i++) {
      for (var j = 0; j < gridN; j++) {
        final top = rows[i], bottom = rows[i + 1];
        final left = cols[j], right = cols[j + 1];
        final cw = max(1, right - left);
        final ch = max(1, bottom - top);

        // crop without padding (cells are always inside the patch)
        final cell = img.Image(width: cw, height: ch);
        for (var y = 0; y < ch; y++) {
          for (var x = 0; x < cw; x++) {
            cell.setPixel(x, y, squarePatch.getPixel(left + x, top + y));
          }
        }

        final feats = _computeBasicFeatures(cell);
        cellMeans[i][j] = feats.meanLuma;
        cellStds[i][j] = feats.stdLuma;
      }
    }

    final out = <String, dynamic>{};
    for (var i = 0; i < gridN; i++) {
      for (var j = 0; j < gridN; j++) {
        out['${prefix}_cell_r${i}_c${j}_mean_luma'] = cellMeans[i][j];
        out['${prefix}_cell_r${i}_c${j}_std_luma'] = cellStds[i][j];
      }
    }

    // relational summaries
    double avg(List<double> xs) => xs.reduce((a, b) => a + b) / xs.length;

    final topRow = cellMeans[0];
    final bottomRow = cellMeans[gridN - 1];
    final leftCol = [for (var i = 0; i < gridN; i++) cellMeans[i][0]];
    final rightCol = [for (var i = 0; i < gridN; i++) cellMeans[i][gridN - 1]];
    final centerVal = cellMeans[gridN ~/ 2][gridN ~/ 2];
    final cornerVals = [
      cellMeans[0][0],
      cellMeans[0][gridN - 1],
      cellMeans[gridN - 1][0],
      cellMeans[gridN - 1][gridN - 1],
    ];

    final topMean = avg(topRow);
    final bottomMean = avg(bottomRow);
    final leftMean = avg(leftCol);
    final rightMean = avg(rightCol);
    final centerMean = centerVal;
    final cornerMean = avg(cornerVals);

    final flatMeans = [for (final row in cellMeans) ...row];
    final gridMax = flatMeans.reduce(max);
    final gridMin = flatMeans.reduce(min);
    final gridMeanAll = avg(flatMeans);
    double gridVar = 0;
    for (final v in flatMeans) {
      gridVar += (v - gridMeanAll) * (v - gridMeanAll);
    }
    gridVar /= flatMeans.length;
    final gridStd = sqrt(gridVar);

    out['${prefix}_top_mean_luma'] = topMean;
    out['${prefix}_bottom_mean_luma'] = bottomMean;
    out['${prefix}_left_mean_luma'] = leftMean;
    out['${prefix}_right_mean_luma'] = rightMean;
    out['${prefix}_center_cell_mean_luma'] = centerMean;
    out['${prefix}_corner_cells_mean_luma'] = cornerMean;
    out['${prefix}_bottom_minus_top_luma'] = bottomMean - topMean;
    out['${prefix}_right_minus_left_luma'] = rightMean - leftMean;
    out['${prefix}_center_minus_corners_luma'] = centerMean - cornerMean;
    out['${prefix}_grid_range_mean_luma'] = gridMax - gridMin;
    out['${prefix}_grid_std_mean_luma'] = gridStd;

    return out;
  }

  /// Assembles the full named-feature map matching the 110 columns in
  /// feature_master_latest.csv (columns 31-130, excluding metadata).
  static Map<String, double> _buildFeatureMap(
    Map<String, _BasicFeatures> roiFeats,
    _BasicFeatures squareBasic,
    Map<String, dynamic> gridFeats,
  ) {
    final m = <String, double>{};

    // Per-ROI: mean_luma, std_luma, grad_mean, grad_std
    for (final roi in RoiGeometry.roiOrder) {
      final f = roiFeats[roi]!;
      m['${roi}_mean_luma'] = f.meanLuma;
      m['${roi}_std_luma'] = f.stdLuma;
      m['${roi}_grad_mean'] = f.gradMean;
      m['${roi}_grad_std'] = f.gradStd;
    }

    // Corner relational features
    final cornerLumas = [
      for (final roi in RoiGeometry.cornerOrder) roiFeats[roi]!.meanLuma
    ];
    final cornerMeanLuma =
        cornerLumas.reduce((a, b) => a + b) / cornerLumas.length;
    double cornerVar = 0;
    for (final v in cornerLumas) {
      cornerVar += (v - cornerMeanLuma) * (v - cornerMeanLuma);
    }
    cornerVar /= cornerLumas.length;
    final cornerStdLuma = sqrt(cornerVar);
    final cornerRangeLuma =
        cornerLumas.reduce(max) - cornerLumas.reduce(min);

    final cLuma = roiFeats['C']!.meanLuma;

    m['corner_mean_luma'] = cornerMeanLuma;
    m['corner_std_luma'] = cornerStdLuma;
    m['corner_range_luma'] = cornerRangeLuma;
    m['C_minus_corner_mean_luma'] = cLuma - cornerMeanLuma;
    m['C_over_corner_mean_luma'] = cLuma / (cornerMeanLuma + 1e-8);

    for (final roi in RoiGeometry.cornerOrder) {
      m['C_minus_${roi}_luma'] = cLuma - roiFeats[roi]!.meanLuma;
    }

    // Square (whole context) basic features
    m['square_mean_luma'] = squareBasic.meanLuma;
    m['square_std_luma'] = squareBasic.stdLuma;
    m['square_grad_mean'] = squareBasic.gradMean;
    m['square_grad_std'] = squareBasic.gradStd;
    m['square_mean_sat_proxy'] = squareBasic.meanSatProxy;

    // Grid cell + relational features
    gridFeats.forEach((k, v) {
      m[k] = (v as num).toDouble();
    });

    // Cross relational features (ROI vs grid corner cells)
    // UL_minus_squarecell_0_0_luma etc.
    m['UL_minus_squarecell_0_0_luma'] =
        roiFeats['UL']!.meanLuma - (gridFeats['square_cell_r0_c0_mean_luma'] as num).toDouble();
    m['UR_minus_squarecell_0_4_luma'] =
        roiFeats['UR']!.meanLuma - (gridFeats['square_cell_r0_c4_mean_luma'] as num).toDouble();
    m['C_minus_squarecell_2_2_luma'] =
        roiFeats['C']!.meanLuma - (gridFeats['square_cell_r2_c2_mean_luma'] as num).toDouble();
    m['LR_minus_squarecell_4_4_luma'] =
        roiFeats['LR']!.meanLuma - (gridFeats['square_cell_r4_c4_mean_luma'] as num).toDouble();
    m['LL_minus_squarecell_4_0_luma'] =
        roiFeats['LL']!.meanLuma - (gridFeats['square_cell_r4_c0_mean_luma'] as num).toDouble();

    return m;
  }

  /// Some deployed models were trained with raw ROI pixel coordinates
  /// (x_C, y_C, x_UL, ... ) included as features — these are constant
  /// across all training images since capture geometry was fixed, but
  /// the model still expects them as inputs. Supply the actual computed
  /// (possibly resolution-scaled) coordinates here.
  static Map<String, double> _buildCoordFeatureMap(
    Map<String, Point<int>> centers,
  ) {
    final m = <String, double>{};
    for (final roi in RoiGeometry.roiOrder) {
      final c = centers[roi]!;
      m['x_$roi'] = c.x.toDouble();
      m['y_$roi'] = c.y.toDouble();
    }
    return m;
  }
}
