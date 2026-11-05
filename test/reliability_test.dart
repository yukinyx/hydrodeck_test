import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:hydrodeck_test/command_ack_policy.dart';
import 'package:hydrodeck_test/history_interval.dart';
import 'package:hydrodeck_test/login_validation.dart';
import 'package:hydrodeck_test/pump_control_policy.dart';
import 'package:hydrodeck_test/device_presence_policy.dart';
import 'package:hydrodeck_test/hotspot_attempt_policy.dart';
import 'package:hydrodeck_test/wifi_provisioning_policy.dart';

void main() {
  sqfliteFfiInit();

  group('hotspot retry and device presence', () {
    test('hotspot failures stay friendly and a finished attempt can retry', () {
      final gate = HotspotAttemptGate();
      expect(gate.tryBegin(), isTrue);
      expect(gate.isActive, isTrue);
      expect(gate.tryBegin(), isFalse);
      expect(
        hotspotFailureMessage(HotspotFailureStage.discovery),
        'Failed to find or connect to the ESP32. Please try again.',
      );
      expect(
        hotspotFailureMessage(HotspotFailureStage.connection),
        hotspotFailureMessage(HotspotFailureStage.discovery),
      );

      gate.finish();
      expect(gate.isActive, isFalse);
      expect(gate.tryBegin(), isTrue);
      gate.finish();
    });

    test('heartbeat grace includes normal delay and rejects stale or missing data', () {
      final now = DateTime.utc(2026, 11, 4, 8);
      expect(
        isDeviceHeartbeatFresh(
          now.subtract(const Duration(seconds: 55)).millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
      expect(
        isDeviceHeartbeatFresh(
          now.subtract(const Duration(seconds: 61)).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
      expect(isDeviceHeartbeatFresh(null, now: now), isFalse);
      expect(
        isDeviceHeartbeatFresh(
          now.add(const Duration(seconds: 6)).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('Manila history intervals', () {
    test('uses fixed half-hour keys and UTC instants', () {
      final firstHalf = DateTime.utc(2026, 10, 17, 2, 15);
      final secondHalf = DateTime.utc(2026, 10, 17, 2, 45);

      expect(manilaIntervalKey(firstHalf), '20261017_1000');
      expect(manilaIntervalKey(secondHalf), '20261017_1030');
      expect(
        utcFromManilaIntervalKey('20261017_1030'),
        DateTime.utc(2026, 10, 17, 2, 30),
      );
      expect(
        nextManilaIntervalUtc(firstHalf),
        DateTime.utc(2026, 10, 17, 2, 30),
      );
    });

    test(
      'creates stable per-batch record identities and prefers ESP32 data',
      () {
        const intervalKey = '20261017_1030';
        final firstId = scheduledSnapshotRecordId(
          batchNumber: 8,
          intervalKey: intervalKey,
        );
        final retryId = scheduledSnapshotRecordId(
          batchNumber: 8,
          intervalKey: intervalKey,
        );
        final otherBatchId = scheduledSnapshotRecordId(
          batchNumber: 9,
          intervalKey: intervalKey,
        );
        final otherIntervalId = scheduledSnapshotRecordId(
          batchNumber: 8,
          intervalKey: '20261017_1100',
        );

        expect(firstId, retryId);
        expect(otherBatchId, isNot(firstId));
        expect(otherIntervalId, isNot(firstId));
        expect(
          shouldReplaceHistoryRecord(
            existing: {'source': 'esp32', 'readingsComplete': true},
            incoming: {'source': 'app', 'readingsComplete': true},
          ),
          isFalse,
        );
        expect(
          shouldReplaceHistoryRecord(
            existing: {'source': 'app', 'readingsComplete': true},
            incoming: {'source': 'esp32', 'readingsComplete': true},
          ),
          isTrue,
        );
      },
    );

    test('SQLite ignores duplicate record IDs', () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE historical_logs (recordId TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE UNIQUE INDEX idx_historical_logs_record_id ON historical_logs(recordId)',
            );
          },
        ),
      );
      addTearDown(database.close);

      expect(
        await database.insert('historical_logs', {
          'recordId': 'b8_scheduled_20261017_1030',
        }),
        greaterThan(0),
      );
      expect(
        await database.insert('historical_logs', {
          'recordId': 'b8_scheduled_20261017_1030',
        }, conflictAlgorithm: ConflictAlgorithm.ignore),
        0,
      );
      expect(await database.query('historical_logs'), hasLength(1));
    });
  });

  group('pump command policy', () {
    test('keeps chemical pulses timed and water pumps on until switched off', () {
      expect(timedPumpDurationMs('nutrient1'), growBed1PumpDurationMs);
      expect(timedPumpDurationMs('phDown2'), growBed2PumpDurationMs);
      expect(timedPumpDurationMs('waterPump1'), 0);

      final start = decidePumpCommand(
        actuator: 'waterPump1',
        requestedOn: true,
        requestId: 'cmd_water_on',
        pumpActive: false,
        activeRequestId: '',
        rainNodeOnline: true,
      );
      expect(start.start, isTrue);
      expect(start.durationMs, 0);

      final stop = decidePumpCommand(
        actuator: 'waterPump1',
        requestedOn: false,
        requestId: 'cmd_water_off',
        pumpActive: true,
        activeRequestId: 'cmd_water_on',
        rainNodeOnline: false,
      );
      expect(stop.start, isFalse);
      expect(stop.reject, isFalse);
      expect(stop.status, 'accepted');
    });

    test('does not restart duplicate IDs and rejects a new ID while busy', () {
      final duplicateWater = decidePumpCommand(
        actuator: 'waterPump1',
        requestedOn: true,
        requestId: 'cmd_water_same',
        pumpActive: true,
        activeRequestId: 'cmd_water_same',
        rainNodeOnline: true,
      );
      expect(duplicateWater.start, isFalse);
      expect(duplicateWater.alreadyRunningSameCommand, isTrue);
      expect(duplicateWater.durationMs, 0);

      final conflictingWater = decidePumpCommand(
        actuator: 'waterPump1',
        requestedOn: true,
        requestId: 'cmd_water_new',
        pumpActive: true,
        activeRequestId: 'cmd_water_same',
        rainNodeOnline: true,
      );
      expect(conflictingWater.reject, isTrue);

      final duplicate = decidePumpCommand(
        actuator: 'phUp1',
        requestedOn: true,
        requestId: 'cmd_same',
        pumpActive: true,
        activeRequestId: 'cmd_same',
        rainNodeOnline: true,
      );
      expect(duplicate.start, isFalse);
      expect(duplicate.alreadyRunningSameCommand, isTrue);
      expect(duplicate.status, 'running');

      final conflicting = decidePumpCommand(
        actuator: 'phUp1',
        requestedOn: true,
        requestId: 'cmd_new',
        pumpActive: true,
        activeRequestId: 'cmd_same',
        rainNodeOnline: true,
      );
      expect(conflicting.reject, isTrue);
      expect(conflicting.status, 'rejected');
    });

    test('allows water and grow light alongside one chemical pulse', () {
      final water = decidePumpCommand(
        actuator: 'waterPump2',
        requestedOn: true,
        requestId: 'cmd_water_2',
        pumpActive: false,
        activeRequestId: '',
        rainNodeOnline: true,
        activeActuators: {'phUp1'},
      );

      expect(water.start, isTrue);
      expect(water.durationMs, 0);
      expect(
        canStartActuatorAlongside('growLight', {'phUp1', 'waterPump2'}),
        isTrue,
      );
      expect(canStartActuatorAlongside('waterPump1', {'waterPump2'}), isFalse);
      expect(canStartActuatorAlongside('phDown1', {'phUp1'}), isFalse);
    });

    test('rejects either water pump while the RAIN node is offline', () {
      for (final actuator in ['waterPump1', 'waterPump2']) {
        final decision = decidePumpCommand(
          actuator: actuator,
          requestedOn: true,
          requestId: 'cmd_offline_$actuator',
          pumpActive: false,
          activeRequestId: '',
          rainNodeOnline: false,
        );
        expect(decision.start, isFalse);
        expect(decision.reject, isTrue);
        expect(decision.status, 'rejected');
      }
    });

    test('pump deadline comparison survives millis rollover', () {
      expect(millisDeadlineReached(0xfffffffe, 4), isFalse);
      expect(millisDeadlineReached(4, 4), isTrue);
      expect(millisDeadlineReached(6, 4), isTrue);
    });
  });

  group('login and command acknowledgments', () {
    test('validates empty and malformed login fields', () {
      expect(validateLoginFields(email: ' ', password: ''), isNotNull);
      expect(
        validateLoginFields(email: 'not-an-email', password: 'secret'),
        'Please enter a valid email address.',
      );
      expect(
        validateLoginFields(email: 'grower@example.com', password: 'secret'),
        isNull,
      );
    });

    test('validates signup phone, password, and confirmation fields', () {
      expect(validateSignupPhoneField(''), 'Please enter your phone number.');
      expect(
        validateSignupPhoneField('09123456789'),
        isNull,
      );
      expect(
        validateSignupPhoneField('08123456789'),
        'Phone number must be 11 digits and start with 09.',
      );
      expect(
        validateSignupPasswordField('short'),
        'Password must be at least 6 characters.',
      );
      expect(validateConfirmPasswordField('secret1', 'secret2'), 'Passwords do not match.');
    });

    test('recognizes command lifecycle and terminal ack states', () {
      for (final status in commandAckStatuses) {
        expect(isValidCommandAckStatus(status), isTrue);
      }
      expect(isTerminalCommandAckStatus('accepted'), isFalse);
      expect(isTerminalCommandAckStatus('running'), isFalse);
      expect(isTerminalCommandAckStatus('completed'), isTrue);
      expect(isTerminalCommandAckStatus('rejected'), isTrue);
      expect(isTerminalCommandAckStatus('timed_out'), isTrue);
      expect(isValidCommandAckStatus('failed'), isFalse);
    });

    test('releases pending command state after terminal ack or timeout', () {
      expect(shouldReleasePendingCommand(status: 'accepted'), isFalse);
      expect(shouldReleasePendingCommand(status: 'running'), isFalse);
      expect(shouldReleasePendingCommand(status: 'rejected'), isTrue);
      expect(shouldReleasePendingCommand(status: 'timed_out'), isTrue);
      expect(shouldReleasePendingCommand(timedOut: true), isTrue);
    });

    test('failed local dispatch without Firebase clears pending state', () {
      expect(
        shouldClearPendingAfterDispatch(
          localAccepted: false,
          firebaseQueued: false,
        ),
        isTrue,
      );
      expect(
        shouldClearPendingAfterDispatch(
          localAccepted: true,
          firebaseQueued: false,
        ),
        isFalse,
      );
      expect(
        shouldClearPendingAfterDispatch(
          localAccepted: false,
          firebaseQueued: true,
        ),
        isFalse,
      );
    });

    test('releases confirmed water starts and terminal failures', () {
      expect(isConfirmedWaterPumpOnAck('waterPump1', 'accepted'), isFalse);
      expect(isConfirmedWaterPumpOnAck('waterPump1', 'running'), isTrue);
      expect(isConfirmedWaterPumpOnAck('phUp1', 'running'), isFalse);
      expect(isTerminalCommandAckStatus('rejected'), isTrue);
      expect(isTerminalCommandAckStatus('timed_out'), isTrue);
    });

    test('maps Wi-Fi provisioning results to accurate messages', () {
      expect(isWifiProvisioningPending('testing'), isTrue);
      expect(isWifiProvisioningPending('connected'), isFalse);
      expect(wifiProvisioningMessage('connected'), contains('successfully'));
      expect(
        wifiProvisioningMessage('authentication_failed'),
        contains('check the Wi-Fi password'),
      );
      expect(
        wifiProvisioningMessage('network_unavailable'),
        contains('Could not find'),
      );
      expect(wifiProvisioningMessage('connection_failed'), contains('found'));
      expect(wifiProvisioningMessage('timeout'), contains('timed out'));
    });

    test('names command targets and distinguishes command failure outcomes', () {
      expect(commandActuatorLabel('waterPump1'), 'Water pump — grow bed 1');
      expect(commandActuatorLabel('phUp2'), 'pH up pump — grow bed 2');
      expect(commandActuatorLabel('nutrient1'), 'Nutrient pump — grow bed 1');
      expect(
        friendlyCommandFailureMessage(status: 'rejected', reason: 'max_run'),
        contains('maximum run time'),
      );
      expect(
        friendlyCommandFailureMessage(status: 'timed_out'),
        contains('timed out'),
      );
      expect(
        friendlyCommandFailureMessage(status: 'offline'),
        contains('offline or unreachable'),
      );
      expect(
        friendlyCommandFailureMessage(status: 'unconfirmed'),
        contains('not confirmed'),
      );
    });
  });
}
