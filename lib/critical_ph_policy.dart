const Duration criticalPhNotificationDelay = Duration(minutes: 5);

class CriticalPhEpisode {
  DateTime? _startedAt;
  bool _notified = false;

  String? get notificationId => _startedAt?.microsecondsSinceEpoch.toString();

  bool shouldNotify({
    required double? ph,
    required double minimum,
    required double maximum,
    required DateTime now,
  }) {
    if (ph == null ||
        !ph.isFinite ||
        ph < 0 ||
        ph > 14 ||
        !minimum.isFinite ||
        !maximum.isFinite ||
        minimum >= maximum ||
        (ph >= minimum && ph <= maximum)) {
      reset();
      return false;
    }

    _startedAt ??= now;
    return !_notified &&
        now.difference(_startedAt!) > criticalPhNotificationDelay;
  }

  void markNotified() {
    _notified = true;
  }

  void reset() {
    _startedAt = null;
    _notified = false;
  }
}
