const Duration deviceHeartbeatInterval = Duration(seconds: 15);
const Duration deviceHeartbeatGracePeriod = Duration(seconds: 60);
const Duration deviceHeartbeatFutureSkewTolerance = Duration(seconds: 5);
const Duration rainStatusGracePeriod = Duration(seconds: 45);
const Duration rainStatusFutureSkewTolerance = Duration(seconds: 5);

bool isDeviceHeartbeatFresh(int? heartbeatMillis, {DateTime? now}) {
  if (heartbeatMillis == null) return false;
  final age = (now ?? DateTime.now()).millisecondsSinceEpoch - heartbeatMillis;
  return age >= -deviceHeartbeatFutureSkewTolerance.inMilliseconds &&
      age <= deviceHeartbeatGracePeriod.inMilliseconds;
}

bool isRainStatusFresh(int? updatedAtMillis, {DateTime? now}) {
  if (updatedAtMillis == null) return false;
  final age = (now ?? DateTime.now()).millisecondsSinceEpoch - updatedAtMillis;
  return age >= -rainStatusFutureSkewTolerance.inMilliseconds &&
      age <= rainStatusGracePeriod.inMilliseconds;
}
