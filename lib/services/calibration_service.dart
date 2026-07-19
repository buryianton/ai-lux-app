// lib/services/calibration_service.dart
//
// Per-device calibration with NAMED PROFILES and a master on/off switch.
//
// Why profiles: a calibration is only valid for the context it was
// collected in (lighting type, surface). Field data shows the native
// capture path can be near-exact under one lamp and +40% under another,
// so one global curve cannot serve both. Users create a profile per
// context (e.g. "office_led", "home_warm") and switch between them.
//
// Fit: lux_true = exp(a) * lux_pred^b, per profile, per source path
// ('capture'/'upload'), per model. Fits refresh automatically when
// points change.
//
// Files (next to the measurement CSVs, pullable/shareable):
//   calibration_points.json    — all points (each tagged with profile)
//   calibration_fits.json      — {profile: {source: {model: {a,b,n}}}}
//   calibration_settings.json  — {"active": "...", "enabled": true}
//
// Backward compatible: old points without a profile tag are treated as
// profile "default".

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';

import 'inference_service.dart';

class CalibrationPoint {
  final String timestamp;
  final String source; // 'capture' | 'upload'
  final String profile;
  final String device;
  final double meterLux;
  final Map<String, double> preds;

  CalibrationPoint({
    required this.timestamp,
    required this.source,
    required this.profile,
    this.device = '',
    required this.meterLux,
    required this.preds,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp,
        'source': source,
        'profile': profile,
        'device': device,
        'meter_lux': meterLux,
        'preds': preds,
      };

  static CalibrationPoint fromJson(Map<String, dynamic> j) =>
      CalibrationPoint(
        timestamp: j['timestamp'] as String,
        source: j['source'] as String,
        profile: (j['profile'] as String?) ?? 'default',
        device: (j['device'] as String?) ?? '',
        meterLux: (j['meter_lux'] as num).toDouble(),
        preds: (j['preds'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, (v as num).toDouble())),
      );
}

class CalibrationFit {
  final double a, b; // power-law fallback: lux = exp(a) * raw^b
  final int n;
  // Optional monotone piecewise curve in log-log space (preferred when
  // enough points exist): sorted log(pred) breakpoints + isotonic
  // log(meter) values. Captures S-shaped tone-curve distortion that a
  // straight power law cannot.
  final List<double>? xs; // log(pred), ascending
  final List<double>? ys; // isotonic log(meter)

  CalibrationFit(
      {required this.a, required this.b, required this.n, this.xs, this.ys});

  double apply(double rawLux) {
    final x = math.log(math.max(rawLux, 1e-6));
    final px = xs, py = ys;
    if (px != null && py != null && px.length >= 2) {
      if (x <= px.first) {
        // extrapolate below range with power-law slope through first point
        return math.exp(py.first + b * (x - px.first));
      }
      if (x >= px.last) {
        return math.exp(py.last + b * (x - px.last));
      }
      var i = 1;
      while (i < px.length && px[i] < x) {
        i++;
      }
      final x0 = px[i - 1], x1 = px[i], y0 = py[i - 1], y1 = py[i];
      final tFrac = (x - x0) / (x1 - x0);
      return math.exp(y0 + tFrac * (y1 - y0));
    }
    return math.exp(a + b * x);
  }

  Map<String, dynamic> toJson() => {
        'a': a,
        'b': b,
        'n': n,
        if (xs != null) 'xs': xs,
        if (ys != null) 'ys': ys,
      };
  static CalibrationFit fromJson(Map<String, dynamic> j) => CalibrationFit(
      a: (j['a'] as num).toDouble(),
      b: (j['b'] as num).toDouble(),
      n: j['n'] as int,
      xs: (j['xs'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      ys: (j['ys'] as List?)?.map((e) => (e as num).toDouble()).toList());
}

class CalibrationService {
  static const minPoints = 5;
  static const defaultProfile = 'default';

  static Future<Directory> _dir() async =>
      await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();

  static Future<File> _f(String name) async =>
      File('${(await _dir()).path}${Platform.pathSeparator}$name');

  static Future<File> _pointsFile() => _f('calibration_points.json');
  static Future<File> _fitsFile() => _f('calibration_fits.json');
  static Future<File> _settingsFile() => _f('calibration_settings.json');

  // ── Settings: active profile + enabled switch ───────────────────────

  static Future<Map<String, dynamic>> _settings() async {
    final f = await _settingsFile();
    if (!await f.exists()) return {'active': defaultProfile, 'enabled': true};
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {'active': defaultProfile, 'enabled': true};
    }
  }

  static Future<void> _saveSettings(Map<String, dynamic> s) async {
    final f = await _settingsFile();
    await f.writeAsString(jsonEncode(s), flush: true);
  }

  static Future<String> activeProfile() async =>
      (await _settings())['active'] as String? ?? defaultProfile;

  static Future<bool> isEnabled() async =>
      (await _settings())['enabled'] as bool? ?? true;

  static Future<void> setActiveProfile(String name) async {
    final s = await _settings();
    s['active'] = _sanitize(name);
    await _saveSettings(s);
  }

  static Future<void> setEnabled(bool enabled) async {
    final s = await _settings();
    s['enabled'] = enabled;
    await _saveSettings(s);
  }

  static String _sanitize(String name) {
    var n = name.trim().replaceAll(RegExp(r'[^\w\- ]'), '_');
    return n.isEmpty ? defaultProfile : n;
  }

  /// All profile names that exist (from points) plus the active one.
  static Future<List<String>> listProfiles() async {
    final pts = await loadPoints();
    final names = <String>{defaultProfile, await activeProfile()};
    for (final p in pts) {
      names.add(p.profile);
    }
    final list = names.toList()..sort();
    return list;
  }

  // ── Points ──────────────────────────────────────────────────────────

  static Future<List<CalibrationPoint>> loadPoints() async {
    final f = await _pointsFile();
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      return [
        for (final e in list)
          CalibrationPoint.fromJson(e as Map<String, dynamic>)
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _savePoints(List<CalibrationPoint> pts) async {
    final f = await _pointsFile();
    await f.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert([for (final p in pts) p.toJson()]),
        flush: true);
  }

  /// Adds a point to the ACTIVE profile and refits. Returns the number
  /// of points now stored for (active profile, that source).
  static Future<int> addPoint({
    required String timestamp,
    required String source,
    required double meterLux,
    required Map<String, double> preds,
  }) async {
    final profile = await activeProfile();
    final pts = await loadPoints();
    pts.add(CalibrationPoint(
        timestamp: timestamp,
        source: source,
        profile: profile,
        device: InferenceService.deviceModel,
        meterLux: meterLux,
        preds: preds));
    await _savePoints(pts);
    await _refit(pts);
    return pts
        .where((x) => x.profile == profile && x.source == source)
        .length;
  }

  /// Deletes by GLOBAL index into loadPoints() ordering.
  static Future<void> deletePoint(int index) async {
    final pts = await loadPoints();
    if (index < 0 || index >= pts.length) return;
    pts.removeAt(index);
    await _savePoints(pts);
    await _refit(pts);
  }

  /// Deletes all points of one profile only.
  static Future<void> clearProfile(String profile) async {
    final pts = await loadPoints();
    pts.removeWhere((p) => p.profile == profile);
    await _savePoints(pts);
    await _refit(pts);
  }

  static Future<void> clearAll() async {
    await _savePoints([]);
    final f = await _fitsFile();
    if (await f.exists()) await f.delete();
  }

  // ── Fitting ─────────────────────────────────────────────────────────

  /// Minimum points before the piecewise (isotonic) curve is used on
  /// top of the power law. Below this, power law alone.
  static const piecewiseMinPoints = 8;

  static CalibrationFit? _fitPairs(List<(double, double)> pairs) {
    if (pairs.length < minPoints) return null;
    final lp = [for (final p in pairs) math.log(math.max(p.$1, 1e-6))];
    final lt = [for (final p in pairs) math.log(math.max(p.$2, 1e-6))];
    final n = pairs.length;
    final mp = lp.reduce((x, y) => x + y) / n;
    final mt = lt.reduce((x, y) => x + y) / n;
    var cov = 0.0, varp = 0.0;
    for (var i = 0; i < n; i++) {
      cov += (lp[i] - mp) * (lt[i] - mt);
      varp += (lp[i] - mp) * (lp[i] - mp);
    }
    if (varp < 1e-12) return null;
    final b = cov / varp;
    final a = mt - b * mp;

    List<double>? xs;
    List<double>? ys;
    if (n >= piecewiseMinPoints) {
      // sort by log(pred); average duplicate x; isotonic (PAV) on y
      final order = List<int>.generate(n, (i) => i)
        ..sort((i, j) => lp[i].compareTo(lp[j]));
      final sx = <double>[];
      final sy = <double>[];
      for (final i in order) {
        if (sx.isNotEmpty && (lp[i] - sx.last).abs() < 1e-9) {
          sy[sy.length - 1] = (sy.last + lt[i]) / 2;
        } else {
          sx.add(lp[i]);
          sy.add(lt[i]);
        }
      }
      // pool-adjacent-violators for monotone non-decreasing y
      final bv = <double>[];
      final bw = <double>[];
      final bc = <int>[]; // how many x-knots each block covers
      for (final v in sy) {
        bv.add(v);
        bw.add(1);
        bc.add(1);
        while (bv.length > 1 && bv[bv.length - 2] > bv.last) {
          final v2 = bv.removeLast(), w2 = bw.removeLast(),
              c2 = bc.removeLast();
          final v1 = bv.removeLast(), w1 = bw.removeLast(),
              c1 = bc.removeLast();
          bv.add((v1 * w1 + v2 * w2) / (w1 + w2));
          bw.add(w1 + w2);
          bc.add(c1 + c2);
        }
      }
      final iso = <double>[];
      for (var k = 0; k < bv.length; k++) {
        for (var c = 0; c < bc[k]; c++) {
          iso.add(bv[k]);
        }
      }
      xs = sx;
      ys = iso;
    }
    return CalibrationFit(a: a, b: b, n: n, xs: xs, ys: ys);
  }

  static Future<void> _refit(List<CalibrationPoint> pts) async {
    final out = <String, Map<String, Map<String, dynamic>>>{};
    final profiles = <String>{for (final p in pts) p.profile};
    for (final profile in profiles) {
      for (final source in ['capture', 'upload']) {
        final sp = pts
            .where((p) => p.profile == profile && p.source == source)
            .toList();
        if (sp.length < minPoints) continue;
        final models = <String>{for (final p in sp) ...p.preds.keys};
        final fits = <String, dynamic>{};
        for (final m in models) {
          final pairs = <(double, double)>[
            for (final p in sp)
              if (p.preds.containsKey(m)) (p.preds[m]!, p.meterLux)
          ];
          final fit = _fitPairs(pairs);
          if (fit != null) fits[m] = fit.toJson();
        }
        if (fits.isNotEmpty) {
          out.putIfAbsent(profile, () => {})[source] =
              fits.cast<String, dynamic>();
        }
      }
    }
    final f = await _fitsFile();
    await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(out),
        flush: true);
  }

  /// Fits for one source in the ACTIVE profile. Returns {} when
  /// calibration is switched OFF — callers then show raw values.
  static Future<Map<String, CalibrationFit>> fitsForSource(
      String source) async {
    if (!await isEnabled()) return {};
    return fitsFor(await activeProfile(), source);
  }

  /// Fits for an explicit (profile, source) pair.
  static Future<Map<String, CalibrationFit>> fitsFor(
      String profile, String source) async {
    final f = await _fitsFile();
    if (!await f.exists()) return {};
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      // Backward compat: old format was {source: {model: fit}}
      final root = j.containsKey('capture') || j.containsKey('upload')
          ? (profile == defaultProfile ? j : <String, dynamic>{})
          : (j[profile] as Map<String, dynamic>? ?? {});
      final s = root[source] as Map<String, dynamic>?;
      if (s == null) return {};
      return s.map((k, v) =>
          MapEntry(k, CalibrationFit.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  /// Imports calibration data from a JSON string. Accepts either a
  /// points file (list) — points are merged and fits recomputed locally —
  /// or a fits file (map) — fitted curves merged per profile. Returns a
  /// short human-readable summary.
  static Future<String> importJson(String content) async {
    final decoded = jsonDecode(content);
    if (decoded is List) {
      final incoming = [
        for (final e in decoded)
          CalibrationPoint.fromJson(e as Map<String, dynamic>)
      ];
      final pts = await loadPoints();
      pts.addAll(incoming);
      await _savePoints(pts);
      await _refit(pts);
      final profiles = {for (final p in incoming) p.profile};
      return 'Imported ${incoming.length} points into profiles: '
          '${profiles.join(", ")}';
    }
    if (decoded is Map<String, dynamic>) {
      // fits file: {profile: {source: {model: fit}}} (or legacy
      // {source: {model: fit}} -> default profile)
      final f = await _fitsFile();
      Map<String, dynamic> current = {};
      if (await f.exists()) {
        try {
          current = jsonDecode(await f.readAsString())
              as Map<String, dynamic>;
        } catch (_) {}
      }
      final incoming = decoded.containsKey('capture') ||
              decoded.containsKey('upload')
          ? {defaultProfile: decoded}
          : decoded;
      var nProfiles = 0;
      incoming.forEach((profile, sources) {
        current[profile] = sources;
        nProfiles++;
      });
      await f.writeAsString(
          const JsonEncoder.withIndent('  ').convert(current),
          flush: true);
      return 'Imported fitted curves for $nProfiles profile(s): '
          '${incoming.keys.join(", ")}';
    }
    throw const FormatException('Unrecognized calibration file format');
  }

  /// The calibration files, for sharing/export.
  static Future<List<File>> exportFiles() async =>
      [await _pointsFile(), await _fitsFile(), await _settingsFile()];
}
