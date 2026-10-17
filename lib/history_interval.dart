import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Scheduled planting-session snapshots use fixed 30-minute clock boundaries
/// in the IANA zone `Asia/Manila`.
///
/// A scheduled record is labeled with the **interval start** (for example
/// 10:00 or 10:30 PHT). Sensor fields are the readings captured at or near
/// that boundary from the authoritative source (ESP32 when available).
/// Missed intervals are skipped; they are never backfilled with later values.
const Duration historySnapshotInterval = Duration(minutes: 30);
const String manilaTimeZoneName = 'Asia/Manila';
const String scheduledSnapshotRecordType = 'scheduled';
const String eventSnapshotRecordType = 'event';

bool _timeZonesInitialized = false;

void initializeHydrodeckTimeZones() {
  if (_timeZonesInitialized) return;
  tzdata.initializeTimeZones();
  _timeZonesInitialized = true;
}

tz.Location manilaLocation() {
  initializeHydrodeckTimeZones();
  return tz.getLocation(manilaTimeZoneName);
}

/// Wall-clock time in Asia/Manila for [timestamp].
tz.TZDateTime manilaDateTime(DateTime timestamp) {
  return tz.TZDateTime.from(timestamp.toUtc(), manilaLocation());
}

DateTime _intervalStartManila(DateTime timestamp) {
  final manila = manilaDateTime(timestamp);
  final slotMinute = manila.minute < 30 ? 0 : 30;
  return tz.TZDateTime(
    manilaLocation(),
    manila.year,
    manila.month,
    manila.day,
    manila.hour,
    slotMinute,
  );
}

/// UTC instant of the Manila half-hour interval that contains [timestamp].
DateTime manilaIntervalStartUtc(DateTime timestamp) {
  return _intervalStartManila(timestamp).toUtc();
}

DateTime? utcFromManilaIntervalKey(String intervalKey) {
  if (intervalKey.length < 13) return null;
  final year = int.tryParse(intervalKey.substring(0, 4));
  final month = int.tryParse(intervalKey.substring(4, 6));
  final day = int.tryParse(intervalKey.substring(6, 8));
  final hour = int.tryParse(intervalKey.substring(9, 11));
  final minute = int.tryParse(intervalKey.substring(11, 13));
  if (year == null || month == null || day == null || hour == null || minute == null) {
    return null;
  }
  return tz.TZDateTime(manilaLocation(), year, month, day, hour, minute).toUtc();
}

/// Stable Manila interval key, e.g. `20261017_1030`.
String manilaIntervalKey(DateTime timestamp) {
  final start = _intervalStartManila(timestamp);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${start.year}${two(start.month)}${two(start.day)}_'
      '${two(start.hour)}${two(start.minute)}';
}

/// Next exclusive Manila half-hour boundary after [timestamp], as UTC.
DateTime nextManilaIntervalUtc(DateTime timestamp) {
  final start = _intervalStartManila(timestamp);
  final next = start.add(historySnapshotInterval);
  if (!next.toUtc().isAfter(timestamp.toUtc())) {
    return next.add(historySnapshotInterval).toUtc();
  }
  return next.toUtc();
}

Duration delayUntilNextManilaInterval(DateTime timestamp) {
  final next = nextManilaIntervalUtc(timestamp);
  final wait = next.difference(timestamp.toUtc());
  if (wait.isNegative) return Duration.zero;
  return wait;
}

String scheduledSnapshotRecordId({
  required int batchNumber,
  required String intervalKey,
}) {
  return 'b${batchNumber}_${scheduledSnapshotRecordType}_$intervalKey';
}

String eventSnapshotRecordId({
  required int batchNumber,
  required String eventName,
  required DateTime at,
}) {
  return 'b${batchNumber}_${eventSnapshotRecordType}_${eventName}_'
      '${at.toUtc().millisecondsSinceEpoch}';
}

String historyIdentity({
  required int batchNumber,
  required String recordType,
  required String intervalOrEventKey,
}) {
  return 'b${batchNumber}_${recordType}_$intervalOrEventKey';
}

String firestoreScheduledDocumentId({
  required int batchNumber,
  required String intervalKey,
}) {
  return scheduledSnapshotRecordId(
    batchNumber: batchNumber,
    intervalKey: intervalKey,
  );
}

/// Prefer the ESP32 snapshot. Never replace a complete record with incomplete
/// or later phone-only data.
bool shouldReplaceHistoryRecord({
  required Map<String, dynamic> existing,
  required Map<String, dynamic> incoming,
}) {
  final existingSource = existing['source']?.toString();
  final incomingSource = incoming['source']?.toString();
  if (existingSource == 'esp32' && incomingSource != 'esp32') return false;
  if (incomingSource == 'esp32' && existingSource != 'esp32') return true;
  final existingComplete = existing['readingsComplete'] == true;
  final incomingComplete = incoming['readingsComplete'] == true;
  if (existingComplete && !incomingComplete) return false;
  if (!existingComplete && incomingComplete) return true;
  return false;
}

Map<String, T> mergeHistoryByIdentity<T>(
  Iterable<T> records,
  String Function(T record) identityOf,
) {
  final merged = <String, T>{};
  for (final record in records) {
    merged.putIfAbsent(identityOf(record), () => record);
  }
  return merged;
}
