/// Stylish action combo rank tiers.
enum ComboRank {
  none('-'),
  d('D'),
  c('C'),
  b('B'),
  a('A'),
  s('S'),
  ss('SS'),
  sss('SSS');

  final String badge;
  const ComboRank(this.badge);
}

/// Arcade combo chain, decay timer, score multiplier & style rank tracker.
final class ComboTracker {
  final double decayDuration;
  final double multiplierStep;
  final double maxMultiplier;

  int _count = 0;
  int _bestCombo = 0;
  double _remainingTime = 0.0;
  double _totalScore = 0.0;
  ComboRank _rank = ComboRank.none;

  void Function(ComboRank prevRank, ComboRank newRank)? onRankChanged;
  void Function(int finalCount)? onComboBroken;

  ComboTracker({
    this.decayDuration = 3.0,
    this.multiplierStep = 0.25,
    this.maxMultiplier = 8.0,
    this.onRankChanged,
    this.onComboBroken,
  });

  int get count => _count;
  int get bestCombo => _bestCombo;
  double get remainingTime => _remainingTime;
  double get decayFraction =>
      decayDuration <= 0.0 ? 0.0 : (_remainingTime / decayDuration).clamp(0.0, 1.0);
  double get totalScore => _totalScore;
  ComboRank get rank => _rank;

  double get multiplier {
    if (_count <= 0) return 1.0;
    final raw = 1.0 + (_count - 1) * multiplierStep;
    return raw > maxMultiplier ? maxMultiplier : raw;
  }

  /// Registers a hit/action, extends decay timer, updates rank & awards scaled score.
  double registerHit({double basePoints = 100.0, double bonusTime = 0.0}) {
    _count++;
    if (_count > _bestCombo) _bestCombo = _count;
    _remainingTime = decayDuration + bonusTime;
    final awarded = basePoints * multiplier;
    _totalScore += awarded;
    _updateRank();
    return awarded;
  }

  void step(double dt) {
    if (_count <= 0 || dt <= 0.0) return;
    _remainingTime -= dt;
    if (_remainingTime <= 0.0) {
      breakCombo();
    }
  }

  void breakCombo() {
    if (_count == 0) return;
    final lost = _count;
    _count = 0;
    _remainingTime = 0.0;
    _updateRank();
    onComboBroken?.call(lost);
  }

  void resetScore() {
    breakCombo();
    _bestCombo = 0;
    _totalScore = 0.0;
  }

  void _updateRank() {
    final ComboRank next;
    if (_count >= 50) {
      next = ComboRank.sss;
    } else if (_count >= 35) {
      next = ComboRank.ss;
    } else if (_count >= 25) {
      next = ComboRank.s;
    } else if (_count >= 16) {
      next = ComboRank.a;
    } else if (_count >= 10) {
      next = ComboRank.b;
    } else if (_count >= 5) {
      next = ComboRank.c;
    } else if (_count >= 1) {
      next = ComboRank.d;
    } else {
      next = ComboRank.none;
    }
    if (next != _rank) {
      final prev = _rank;
      _rank = next;
      onRankChanged?.call(prev, next);
    }
  }
}

/// Single ranked entry in a [Leaderboard].
final class LeaderboardEntry {
  final String playerId;
  final String displayName;
  final double score;
  final int timestampMs;
  final Map<String, Object?> metadata;

  const LeaderboardEntry({
    required this.playerId,
    required this.displayName,
    required this.score,
    this.timestampMs = 0,
    this.metadata = const {},
  });

  Map<String, Object?> toJson() => {
        'playerId': playerId,
        'displayName': displayName,
        'score': score,
        'timestampMs': timestampMs,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  factory LeaderboardEntry.fromJson(Map<String, Object?> json) => LeaderboardEntry(
        playerId: json['playerId'] as String? ?? 'unknown',
        displayName: json['displayName'] as String? ?? 'Player',
        score: (json['score'] as num?)?.toDouble() ?? 0.0,
        timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
        metadata: (json['metadata'] as Map?)?.cast<String, Object?>() ?? const {},
      );
}

/// Deterministic sorted leaderboard supporting high-score or speedrun ordering.
final class Leaderboard {
  final String boardId;
  final bool higherIsBetter;
  final int maxEntries;
  final bool keepBestPerPlayer;
  final List<LeaderboardEntry> _entries = [];

  Leaderboard({
    required this.boardId,
    this.higherIsBetter = true,
    this.maxEntries = 100,
    this.keepBestPerPlayer = true,
  });

  List<LeaderboardEntry> get entries => List.unmodifiable(_entries);

  int _compare(LeaderboardEntry a, LeaderboardEntry b) {
    final scoreCmp =
        higherIsBetter ? b.score.compareTo(a.score) : a.score.compareTo(b.score);
    if (scoreCmp != 0) return scoreCmp;
    return a.timestampMs.compareTo(b.timestampMs);
  }

  /// Submits [entry] and returns its 1-based rank if present in top [maxEntries], else `null`.
  int? submit(LeaderboardEntry entry) {
    if (keepBestPerPlayer) {
      final existingIdx =
          _entries.indexWhere((e) => e.playerId == entry.playerId);
      if (existingIdx != -1) {
        final existing = _entries[existingIdx];
        final isBetter = higherIsBetter
            ? entry.score > existing.score
            : entry.score < existing.score;
        if (!isBetter) {
          return existingIdx + 1;
        }
        _entries.removeAt(existingIdx);
      }
    }

    _entries.add(entry);
    _entries.sort(_compare);
    if (maxEntries > 0 && _entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    final newIdx = _entries.indexWhere((e) => identical(e, entry));
    return newIdx == -1 ? null : newIdx + 1;
  }

  int? rankOf(String playerId) {
    final idx = _entries.indexWhere((e) => e.playerId == playerId);
    return idx == -1 ? null : idx + 1;
  }

  List<LeaderboardEntry> top([int count = 10]) =>
      _entries.take(count).toList();

  List<LeaderboardEntry> around(String playerId, {int radius = 2}) {
    final idx = _entries.indexWhere((e) => e.playerId == playerId);
    if (idx == -1) return const [];
    final start = (idx - radius).clamp(0, _entries.length);
    final end = (idx + radius + 1).clamp(0, _entries.length);
    return _entries.sublist(start, end);
  }

  void clear() => _entries.clear();

  Map<String, Object?> toJson() => {
        'boardId': boardId,
        'higherIsBetter': higherIsBetter,
        'maxEntries': maxEntries,
        'keepBestPerPlayer': keepBestPerPlayer,
        'entries': _entries.map((e) => e.toJson()).toList(),
      };

  factory Leaderboard.fromJson(Map<String, Object?> json) {
    final board = Leaderboard(
      boardId: json['boardId'] as String? ?? 'default',
      higherIsBetter: json['higherIsBetter'] as bool? ?? true,
      maxEntries: (json['maxEntries'] as num?)?.toInt() ?? 100,
      keepBestPerPlayer: json['keepBestPerPlayer'] as bool? ?? true,
    );
    final rawEntries = json['entries'];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is Map) {
          board.submit(
            LeaderboardEntry.fromJson(item.cast<String, Object?>()),
          );
        }
      }
    }
    return board;
  }
}
