enum HotspotFailureStage { discovery, connection, response }

String hotspotFailureMessage(HotspotFailureStage stage) => switch (stage) {
  HotspotFailureStage.discovery ||
  HotspotFailureStage.connection ||
  HotspotFailureStage.response =>
    'Failed to find or connect to the ESP32. Please try again.',
};

class HotspotAttemptGate {
  bool _isActive = false;

  bool get isActive => _isActive;

  bool tryBegin() {
    if (_isActive) return false;
    _isActive = true;
    return true;
  }

  void finish() {
    _isActive = false;
  }
}
