import 'dart:collection';
import 'metrics.dart';
import 'telemetry.dart';

/// Composable condition rule evaluated against [MetricRegistry] and [TelemetryBus].
abstract class AchievementCondition {
  const AchievementCondition();

  /// Progress normalized to `[0.0, 1.0]`. Reaches `>= 1.0` when satisfied.
  double evaluateProgress(MetricRegistry metrics, TelemetryBus telemetry);

  bool isSatisfied(MetricRegistry metrics, TelemetryBus telemetry) =>
      evaluateProgress(metrics, telemetry) >= 1.0 - 1e-9;
}

/// Satisfied when a metric reaches [targetValue] (or stays `<= targetValue` for speedruns).
final class MetricThresholdCondition extends AchievementCondition {
  final String metricId;
  final double targetValue;
  final bool useSession;
  final bool lessOrEqual;

  const MetricThresholdCondition(
    this.metricId,
    this.targetValue, {
    this.useSession = false,
    this.lessOrEqual = false,
  });

  @override
  double evaluateProgress(MetricRegistry metrics, TelemetryBus telemetry) {
    if (!metrics.hasRecorded(metricId)) return 0.0;
    final val = useSession ? metrics.session(metricId) : metrics.lifetime(metricId);
    if (lessOrEqual) {
      return val <= targetValue ? 1.0 : 0.0;
    }
    if (targetValue <= 0.0) return val >= targetValue ? 1.0 : 0.0;
    return (val / targetValue).clamp(0.0, 1.0);
  }
}

/// Satisfied when a named telemetry event has been observed [requiredCount] times.
final class EventCountCondition extends AchievementCondition {
  final String eventType;
  final int requiredCount;

  const EventCountCondition(this.eventType, {this.requiredCount = 1});

  @override
  double evaluateProgress(MetricRegistry metrics, TelemetryBus telemetry) {
    if (requiredCount <= 0) return 1.0;
    return (telemetry.countFor(eventType) / requiredCount).clamp(0.0, 1.0);
  }
}

/// Satisfied when ALL child conditions succeed.
final class AllOfConditions extends AchievementCondition {
  final List<AchievementCondition> children;

  const AllOfConditions(this.children);

  @override
  double evaluateProgress(MetricRegistry metrics, TelemetryBus telemetry) {
    if (children.isEmpty) return 1.0;
    var sum = 0.0;
    var allMet = true;
    for (final c in children) {
      final p = c.evaluateProgress(metrics, telemetry).clamp(0.0, 1.0);
      sum += p;
      if (p < 1.0 - 1e-9) allMet = false;
    }
    if (allMet) return 1.0;
    return (sum / children.length).clamp(0.0, 0.999);
  }
}

/// Satisfied when ANY child condition succeeds.
final class AnyOfConditions extends AchievementCondition {
  final List<AchievementCondition> children;

  const AnyOfConditions(this.children);

  @override
  double evaluateProgress(MetricRegistry metrics, TelemetryBus telemetry) {
    if (children.isEmpty) return 0.0;
    var best = 0.0;
    for (final c in children) {
      final p = c.evaluateProgress(metrics, telemetry).clamp(0.0, 1.0);
      if (p > best) best = p;
    }
    return best;
  }
}

/// Custom predicate-based progress function (`0.0..1.0`).
final class PredicateCondition extends AchievementCondition {
  final double Function(MetricRegistry metrics, TelemetryBus telemetry) evaluator;

  const PredicateCondition(this.evaluator);

  @override
  double evaluateProgress(MetricRegistry metrics, TelemetryBus telemetry) =>
      evaluator(metrics, telemetry).clamp(0.0, 1.0);
}

/// Declarative achievement definition.
final class AchievementDef {
  final String id;
  final String title;
  final String description;
  final AchievementCondition condition;
  final int points;
  final bool secret;
  final String? iconKey;

  const AchievementDef({
    required this.id,
    required this.title,
    required this.description,
    required this.condition,
    this.points = 10,
    this.secret = false,
    this.iconKey,
  });
}

/// Live unlock & progress state for one registered [AchievementDef].
final class AchievementProgress {
  final AchievementDef def;
  bool unlocked = false;
  double unlockedAtSeconds = 0.0;
  double progress = 0.0;

  AchievementProgress(this.def);

  String get visibleDescription =>
      (def.secret && !unlocked) ? 'Hidden Achievement' : def.description;
}

/// Tracks achievement definitions, reactive evaluation, toast queue & save state.
final class AchievementTracker {
  final MetricRegistry metrics;
  final TelemetryBus telemetry;
  final Map<String, AchievementProgress> _entries = {};
  final Queue<AchievementDef> _toastQueue = Queue();

  void Function(AchievementDef unlocked)? onUnlocked;

  AchievementTracker({
    MetricRegistry? metrics,
    TelemetryBus? telemetry,
    this.onUnlocked,
  })  : metrics = metrics ?? MetricRegistry(),
        telemetry = telemetry ?? TelemetryBus();

  Iterable<AchievementProgress> get all => _entries.values;
  int get unlockedCount => _entries.values.where((a) => a.unlocked).length;
  int get totalCount => _entries.length;
  int get totalPointsEarned => _entries.values
      .where((a) => a.unlocked)
      .fold(0, (sum, a) => sum + a.def.points);
  int get totalPossiblePoints =>
      _entries.values.fold(0, (sum, a) => sum + a.def.points);
  double get completionFraction =>
      _entries.isEmpty ? 0.0 : unlockedCount / _entries.length;

  void register(AchievementDef def) {
    _entries[def.id] = AchievementProgress(def);
  }

  void registerAll(Iterable<AchievementDef> defs) {
    for (final d in defs) {
      register(d);
    }
  }

  AchievementProgress? getState(String id) => _entries[id];
  bool isUnlocked(String id) => _entries[id]?.unlocked ?? false;

  /// Forces an explicit unlock regardless of condition (e.g. story trigger).
  bool unlock(String id) {
    final entry = _entries[id];
    if (entry == null || entry.unlocked) return false;
    entry.unlocked = true;
    entry.progress = 1.0;
    entry.unlockedAtSeconds = telemetry.elapsedSeconds;
    _toastQueue.addLast(entry.def);
    onUnlocked?.call(entry.def);
    return true;
  }

  /// Evaluates all locked achievements against [metrics] and [telemetry].
  /// Returns list of newly unlocked achievements in this pass.
  List<AchievementDef> evaluate() {
    final newlyUnlocked = <AchievementDef>[];
    for (final entry in _entries.values) {
      if (entry.unlocked) {
        entry.progress = 1.0;
        continue;
      }
      final p = entry.def.condition
          .evaluateProgress(metrics, telemetry)
          .clamp(0.0, 1.0);
      entry.progress = p;
      if (p >= 1.0 - 1e-9) {
        entry.unlocked = true;
        entry.unlockedAtSeconds = telemetry.elapsedSeconds;
        _toastQueue.addLast(entry.def);
        newlyUnlocked.add(entry.def);
        onUnlocked?.call(entry.def);
      }
    }
    return newlyUnlocked;
  }

  bool get hasPendingToasts => _toastQueue.isNotEmpty;
  AchievementDef? popToast() =>
      _toastQueue.isEmpty ? null : _toastQueue.removeFirst();

  Map<String, Object?> toJson() => {
        for (final e in _entries.entries)
          e.key: {
            'unlocked': e.value.unlocked,
            'unlockedAt': e.value.unlockedAtSeconds,
            'progress': e.value.progress,
          },
      };

  void loadJson(Map<String, Object?> json) {
    for (final e in json.entries) {
      final entry = _entries[e.key];
      final raw = e.value;
      if (entry == null || raw is! Map) continue;
      entry.unlocked = (raw['unlocked'] as bool?) ?? false;
      entry.unlockedAtSeconds = (raw['unlockedAt'] as num?)?.toDouble() ?? 0.0;
      entry.progress = entry.unlocked
          ? 1.0
          : ((raw['progress'] as num?)?.toDouble() ?? 0.0);
    }
  }
}
