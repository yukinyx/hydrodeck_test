const Duration deviceHeartbeatInterval = Duration(seconds: 15);
const Duration deviceHeartbeatGracePeriod = Duration(seconds: 60);
const Duration deviceHeartbeatFutureSkewTolerance = Duration(seconds: 5);

bool isDeviceHeartbeatFresh(int? heartbeatMillis, {DateTime? now}) {
  if (heartbeatMillis == null) return false;
  final age = (now ?? DateTime.now()).millisecondsSinceEpoch - heartbeatMillis;
  return age >= -deviceHeartbeatFutureSkewTolerance.inMilliseconds &&
      age <= deviceHeartbeatGracePeriod.inMilliseconds;
}
