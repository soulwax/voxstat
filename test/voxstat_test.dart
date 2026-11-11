import 'package:test/test.dart';
import 'package:voxstat/voxstat.dart';

void main() {
  group('TelemetryBus, RollingRateTracker & ScalarHistogram', () {
    test('tracks typed events, sliding window rates and histogram percentiles', () {
      final bus = TelemetryBus(maxHistory: 10);
      final dps = bus.trackRate('damage', windowSeconds: 4.0);
      var observed = 0.0;
      final unsub = bus.on('damage', (e) => observed += e.value);

      bus.emit('damage', value: 100.0);
      bus.step(1.0);
      bus.emit('damage', value: 300.0);

      expect(observed, closeTo(400.0, 1e-6));
      expect(dps.sumInWindow, closeTo(400.0, 1e-6));
      expect(dps.ratePerSecond, closeTo(100.0, 1e-6));

      // Advance past window boundary -> first 100.0 expires!
      bus.step(3.5);
      expect(dps.sumInWindow, closeTo(300.0, 1e-6));

      unsub();
      bus.emit('damage', value: 50.0);
      expect(observed, closeTo(400.0, 1e-6));

      final hist = ScalarHistogram();
      for (final v in [10.0, 20.0, 30.0, 40.0, 100.0]) {
        hist.record(v);
      }
      expect(hist.min, 10.0);
      expect(hist.max, 100.0);
      expect(hist.median, 30.0);
      expect(hist.p95, greaterThan(80.0));
    });
  });

  group('MetricRegistry & Composable AchievementTracker', () {
    test('evaluates compound AllOf/AnyOf/Threshold rules and persists JSON', () {
      final metrics = MetricRegistry();
      metrics.define('best_time', mode: MetricAggregateMode.min);
      final telemetry = TelemetryBus();

      final tracker = AchievementTracker(metrics: metrics, telemetry: telemetry);
      tracker.registerAll([
        const AchievementDef(
          id: 'slayer',
          title: 'Monster Slayer',
          description: 'Defeat 10 enemies',
          points: 20,
          condition: MetricThresholdCondition('kills', 10),
        ),
        const AchievementDef(
          id: 'speed_legend',
          title: 'Speedrun Master',
          description: 'Reach 5 kills and finish in <= 30s',
          points: 50,
          secret: true,
          condition: AllOfConditions([
            MetricThresholdCondition('kills', 5),
            MetricThresholdCondition('best_time', 30.0, lessOrEqual: true),
            EventCountCondition('boss_defeated'),
          ]),
        ),
      ]);

      expect(tracker.getState('speed_legend')!.visibleDescription, 'Hidden Achievement');

      metrics.increment('kills', 5);
      telemetry.emit('boss_defeated');
      metrics.record('best_time', 25.0);
      final firstPass = tracker.evaluate();
      expect(firstPass.map((a) => a.id), ['speed_legend']);
      expect(tracker.getState('speed_legend')!.visibleDescription,
          'Reach 5 kills and finish in <= 30s');
      expect(tracker.getState('slayer')!.progress, closeTo(0.5, 1e-6));

      metrics.increment('kills', 5);
      final secondPass = tracker.evaluate();
      expect(secondPass.map((a) => a.id), ['slayer']);
      expect(tracker.totalPointsEarned, 70);

      // JSON save & reload into a fresh tracker
      final savedMetrics = metrics.toJson();
      final savedAch = tracker.toJson();

      final metrics2 = MetricRegistry()..loadJson(savedMetrics);
      final tracker2 = AchievementTracker(metrics: metrics2)
        ..registerAll(tracker.all.map((a) => a.def))
        ..loadJson(savedAch);
      expect(tracker2.isUnlocked('slayer'), isTrue);
      expect(tracker2.isUnlocked('speed_legend'), isTrue);
      expect(metrics2.lifetime('best_time'), closeTo(25.0, 1e-6));
    });
  });

  group('ComboTracker & Leaderboard', () {
    test('escalates combo rank multiplier, decays on timeout & orders leaderboard ties', () {
      final ranks = <ComboRank>[];
      var brokenCount = 0;
      final combo = ComboTracker(
        decayDuration: 2.0,
        multiplierStep: 0.5,
        onRankChanged: (_, next) => ranks.add(next),
        onComboBroken: (cnt) => brokenCount = cnt,
      );

      for (int i = 0; i < 6; i++) {
        combo.registerHit(basePoints: 100.0);
      }
      expect(combo.count, 6);
      expect(combo.multiplier, closeTo(3.5, 1e-6));
      expect(combo.rank, ComboRank.c);
      expect(ranks, [ComboRank.d, ComboRank.c]);

      combo.step(2.5);
      expect(combo.count, 0);
      expect(brokenCount, 6);

      final board = Leaderboard(boardId: 'arcade', higherIsBetter: true, maxEntries: 3);
      board.submit(const LeaderboardEntry(playerId: 'p1', displayName: 'Alice', score: 1500, timestampMs: 20));
      board.submit(const LeaderboardEntry(playerId: 'p2', displayName: 'Bob', score: 1500, timestampMs: 10));
      board.submit(const LeaderboardEntry(playerId: 'p3', displayName: 'Cara', score: 2400, timestampMs: 30));
      // Lower duplicate score for Cara shouldn't downgrade her rank
      expect(board.submit(const LeaderboardEntry(playerId: 'p3', displayName: 'Cara', score: 900, timestampMs: 40)), 1);

      expect(board.top().map((e) => e.playerId), ['p3', 'p2', 'p1']);
      final restored = Leaderboard.fromJson(board.toJson());
      expect(restored.rankOf('p2'), 2);
    });
  });
}
