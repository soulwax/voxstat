/// Aggregation mode when recording samples for a metric ID.
enum MetricAggregateMode {
  sum,
  max,
  min,
  last,
}

/// Holds both current-session and persistent-lifetime values for one metric.
final class MetricRecord {
  final String id;
  final MetricAggregateMode mode;
  double sessionValue = 0.0;
  double lifetimeValue = 0.0;
  bool _hasSessionSample = false;
  bool _hasLifetimeSample = false;

  MetricRecord({
    required this.id,
    this.mode = MetricAggregateMode.sum,
  });

  bool get hasSample => _hasLifetimeSample;

  void apply(double value) {
    switch (mode) {
      case MetricAggregateMode.sum:
        sessionValue += value;
        lifetimeValue += value;
        break;
      case MetricAggregateMode.max:
        sessionValue = _hasSessionSample
            ? (value > sessionValue ? value : sessionValue)
            : value;
        lifetimeValue = _hasLifetimeSample
            ? (value > lifetimeValue ? value : lifetimeValue)
            : value;
        break;
      case MetricAggregateMode.min:
        sessionValue = _hasSessionSample
            ? (value < sessionValue ? value : sessionValue)
            : value;
        lifetimeValue = _hasLifetimeSample
            ? (value < lifetimeValue ? value : lifetimeValue)
            : value;
        break;
      case MetricAggregateMode.last:
        sessionValue = value;
        lifetimeValue = value;
        break;
    }
    _hasSessionSample = true;
    _hasLifetimeSample = true;
  }

  void resetSession() {
    sessionValue = 0.0;
    _hasSessionSample = false;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'mode': mode.name,
        'lifetime': lifetimeValue,
        'hasSample': _hasLifetimeSample,
      };
}

/// Manages typed gameplay progression metrics across sessions and saves.
final class MetricRegistry {
  final Map<String, MetricRecord> _records = {};
  void Function(String metricId, MetricRecord record)? onMetricChanged;

  MetricRegistry({this.onMetricChanged});

  Iterable<MetricRecord> get records => _records.values;

  void define(String id, {MetricAggregateMode mode = MetricAggregateMode.sum}) {
    _records.putIfAbsent(id, () => MetricRecord(id: id, mode: mode));
  }

  MetricRecord record(
    String id,
    double value, {
    MetricAggregateMode defaultMode = MetricAggregateMode.sum,
  }) {
    final rec = _records.putIfAbsent(
      id,
      () => MetricRecord(id: id, mode: defaultMode),
    );
    rec.apply(value);
    onMetricChanged?.call(id, rec);
    return rec;
  }

  void increment(String id, [double amount = 1.0]) => record(id, amount);

  double lifetime(String id) => _records[id]?.lifetimeValue ?? 0.0;
  double session(String id) => _records[id]?.sessionValue ?? 0.0;
  bool hasRecorded(String id) => _records[id]?.hasSample ?? false;

  void resetSession() {
    for (final rec in _records.values) {
      rec.resetSession();
    }
  }

  Map<String, Object?> toJson() => {
        for (final entry in _records.entries) entry.key: entry.value.toJson(),
      };

  void loadJson(Map<String, Object?> json) {
    for (final entry in json.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final modeName = raw['mode']?.toString() ?? 'sum';
      final mode = MetricAggregateMode.values.firstWhere(
        (m) => m.name == modeName,
        orElse: () => MetricAggregateMode.sum,
      );
      final rec = _records.putIfAbsent(
        entry.key,
        () => MetricRecord(id: entry.key, mode: mode),
      );
      rec.lifetimeValue = (raw['lifetime'] as num?)?.toDouble() ?? 0.0;
      rec._hasLifetimeSample = (raw['hasSample'] as bool?) ?? (rec.lifetimeValue != 0.0);
    }
  }
}
