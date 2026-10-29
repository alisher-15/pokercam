import 'dart:math';

/// Pauses between reconnection attempts (SPEC 6.4, 8.5): 1-2-4-8-10 s, then 10 s for ever.
class Backoff {
  Backoff([List<Duration>? steps])
    : steps =
          steps ??
          const [
            Duration(seconds: 1),
            Duration(seconds: 2),
            Duration(seconds: 4),
            Duration(seconds: 8),
            Duration(seconds: 10),
          ];

  final List<Duration> steps;
  int _attempt = 0;

  /// How many attempts failed since the last [reset].
  int get attempt => _attempt;

  /// The pause before the next attempt.
  Duration next() {
    final step = steps[min(_attempt, steps.length - 1)];
    _attempt++;
    return step;
  }

  /// After a successful connection: the next failure starts from the first pause again.
  void reset() => _attempt = 0;
}
