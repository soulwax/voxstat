import 'dart:collection';
import 'dart:math' as math;

/// Timestamped typed gameplay event emitted onto a [TelemetryBus].
final class TelemetryEvent {
  final String type;
  final double timestamp;
  final double value;
  final Map<String, Object?> payload;

  TelemetryEvent({
    required this.type,
    required this.timestamp,
    this.value = 1.0,
    Map<String, Object?> payload = const {},
  }) : payload = Map.unmodifiable(payload);
}

/// Sliding-window throughput & event-rate counter (e.g., DPS, APM, kills/min).
final class RollingRateTracker {
  final double windowSeconds;
  final Queue<({double time, double value})> _samples = Queue();
  double _sum = 0.0;
  double _clock = 0.0;

  RollingRateTracker({this.windowSeconds = 5.0})
      : assert(windowSeconds > 0.0, 'windowSeconds must be > 0');

  int get countInWindow => _samples.length;
  double get sumInWindow => _sum;
  double get ratePerSecond => _sum / windowSeconds;
  double get ratePerMinute => ratePerSecond * 60.0;

  void addSample(double value, [double? timestamp]) {
    final t = timestamp ?? _clock;
    if (t > _clock) _clock = t;
    _samples.addLast((time: t, value: value));
    _sum += value;
    _prune(t);
  }

  void advance(double dt) {
    if (dt <= 0.0) return;
    _clock += dt;
    _prune(_clock);
  }

  void _prune(double now) {
    final cutoff = now - windowSeconds;
    while (_samples.isNotEmpty && _samples.first.time < cutoff) {
      _sum -= _samples.removeFirst().value;
    }
    if (_samples.isEmpty) _sum = 0.0;
  }

  void clear() {
    _samples.clear();
    _sum = 0.0;
  }
}

/// Exact quantile & summary statistics collector for frame timings, damage rolls, etc.
final class ScalarHistogram {
  final List<double> _samples = [];
  final int maxSamples;
  double _min = double.infinity;
  double _max = double.negativeInfinity;
  double _sum = 0.0;

  ScalarHistogram({this.maxSamples = 4096});

  int get count => _samples.length;
  double get min => _samples.isEmpty ? 0.0 : _min;
  double get max => _samples.isEmpty ? 0.0 : _max;
  double get sum => _sum;
  double get mean => _samples.isEmpty ? 0.0 : _sum / _samples.length;

  double get variance {
    if (_samples.length < 2) return 0.0;
    final m = mean;
    var acc = 0.0;
    for (final s in _samples) {
      final d = s - m;
      acc += d * d;
    }
    return acc / _samples.length;
  }

  double get stdDev => math.sqrt(variance);

  void record(double value) {
    if (_samples.length >= maxSamples && maxSamples > 0) {
      _samples.removeAt(0);
      _recomputeExtremes();
    }
    _samples.add(value);
    if (value < _min) _min = value;
    if (value > _max) _max = value;
    _sum += value;
  }

  void _recomputeExtremes() {
    _min = double.infinity;
    _max = double.negativeInfinity;
    _sum = 0.0;
    for (final s in _samples) {
      if (s < _min) _min = s;
      if (s > _max) _max = s;
      _sum += s;
    }
  }

  /// Returns percentile `p` in `[0.0, 1.0]` (e.g., `0.95` for p95).
  double percentile(double p) {
    if (_samples.isEmpty) return 0.0;
    final sorted = List<double>.from(_samples)..sort();
    final idx = (p.clamp(0.0, 1.0) * (sorted.length - 1));
    final lo = idx.floor();
    final hi = idx.ceil();
    if (lo == hi) return sorted[lo];
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
  }

  double get median => percentile(0.5);
  double get p95 => percentile(0.95);
  double get p99 => percentile(0.99);

  void clear() {
    _samples.clear();
    _min = double.infinity;
    _max = double.negativeInfinity;
    _sum = 0.0;
  }
}

/// Publish-subscribe event bus with per-type counts, rolling rates, and event history.
final class TelemetryBus {
  final int maxHistory;
  final Map<String, List<void Function(TelemetryEvent)>> _listeners = {};
  final List<void Function(TelemetryEvent)> _globalListeners = [];
  final List<TelemetryEvent> _history = [];
  final Map<String, int> _eventCounts = {};
  final Map<String, RollingRateTracker> _rateTrackers = {};

  double _clock = 0.0;

  TelemetryBus({this.maxHistory = 256});

  double get elapsedSeconds => _clock;
  List<TelemetryEvent> get history => List.unmodifiable(_history);

  int countFor(String eventType) => _eventCounts[eventType] ?? 0;

  RollingRateTracker trackRate(String eventType, {double windowSeconds = 5.0}) =>
      _rateTrackers.putIfAbsent(
        eventType,
        () => RollingRateTracker(windowSeconds: windowSeconds),
      );

  /// Subscribes to [eventType] and returns an unsubscribe closure.
  void Function() on(
    String eventType,
    void Function(TelemetryEvent event) listener,
  ) {
    final list = _listeners.putIfAbsent(eventType, () => []);
    list.add(listener);
    return () => list.remove(listener);
  }

  /// Subscribes to every event emitted on this bus. Returns an unsubscribe closure.
  void Function() onAny(void Function(TelemetryEvent event) listener) {
    _globalListeners.add(listener);
    return () => _globalListeners.remove(listener);
  }

  TelemetryEvent emit(
    String type, {
    double value = 1.0,
    Map<String, Object?> payload = const {},
    double? timestamp,
  }) {
    final ts = timestamp ?? _clock;
    if (ts > _clock) _clock = ts;

    final evt = TelemetryEvent(
      type: type,
      timestamp: ts,
      value: value,
      payload: payload,
    );

    _eventCounts[type] = (_eventCounts[type] ?? 0) + 1;
    _rateTrackers[type]?.addSample(value, ts);

    if (maxHistory > 0) {
      if (_history.length >= maxHistory) _history.removeAt(0);
      _history.add(evt);
    }

    final listeners = _listeners[type];
    if (listeners != null) {
      for (final fn in List.of(listeners)) {
        fn(evt);
      }
    }
    for (final fn in List.of(_globalListeners)) {
      fn(evt);
    }
    return evt;
  }

  void step(double dt) {
    if (dt <= 0.0) return;
    _clock += dt;
    for (final tracker in _rateTrackers.values) {
      tracker.advance(dt);
    }
  }

  List<TelemetryEvent> eventsOfType(String type) =>
      _history.where((e) => e.type == type).toList();

  void clearHistory() => _history.clear();
}
