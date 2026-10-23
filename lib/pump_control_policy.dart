/// Firmware-aligned pump policy used by tests and documentation.
/// The MAIN ESP32 owns pump timing and coordinates the RAIN node, which drives
/// the water relays and enforces local failsafes.
const int growBed1PumpDurationMs = 3000;
const int growBed2PumpDurationMs = 5000;

const Set<String> growBed1Actuators = {
  'waterPump1',
  'phUp1',
  'phDown1',
  'nutrient1',
};

const Set<String> growBed2Actuators = {
  'waterPump2',
  'phUp2',
  'phDown2',
  'nutrient2',
};

const Set<String> validRemoteActuators = {
  ...growBed1Actuators,
  ...growBed2Actuators,
  'growLight',
};

/// Timed pulse duration for chemical pumps; water pumps are ON/OFF.
int timedPumpDurationMs(String actuator) {
  if (actuator == 'waterPump1' || actuator == 'waterPump2') return 0;
  if (growBed1Actuators.contains(actuator)) return growBed1PumpDurationMs;
  if (growBed2Actuators.contains(actuator)) return growBed2PumpDurationMs;
  return 0;
}

bool canStartActuatorAlongside(String actuator, Set<String> activeActuators) {
  if (!validRemoteActuators.contains(actuator)) return false;
  if (actuator == 'growLight') return true;
  if (activeActuators.contains(actuator)) return false;

  if (actuator == 'waterPump1') return !activeActuators.contains('waterPump2');
  if (actuator == 'waterPump2') return !activeActuators.contains('waterPump1');

  const chemicalActuators = {
    'phUp1',
    'phDown1',
    'nutrient1',
    'phUp2',
    'phDown2',
    'nutrient2',
  };
  return !activeActuators.any(chemicalActuators.contains);
}

class PumpRunDecision {
  final bool start;
  final bool reject;
  final bool alreadyRunningSameCommand;
  final String status;
  final int durationMs;

  const PumpRunDecision({
    required this.start,
    required this.reject,
    required this.alreadyRunningSameCommand,
    required this.status,
    required this.durationMs,
  });
}

/// Duplicate command IDs must not restart or extend a run. A new ID targeting
/// an already-running pump is rejected.
PumpRunDecision decidePumpCommand({
  required String actuator,
  required bool requestedOn,
  required String requestId,
  required bool pumpActive,
  required String activeRequestId,
  required bool rainNodeOnline,
  Set<String> activeActuators = const {},
}) {
  if (!validRemoteActuators.contains(actuator) || actuator == 'growLight') {
    return const PumpRunDecision(
      start: false,
      reject: true,
      alreadyRunningSameCommand: false,
      status: 'rejected',
      durationMs: 0,
    );
  }
  final isWaterPump = actuator == 'waterPump1' || actuator == 'waterPump2';
  if (!requestedOn) {
    if (!isWaterPump) {
      return const PumpRunDecision(
        start: false,
        reject: true,
        alreadyRunningSameCommand: false,
        status: 'rejected',
        durationMs: 0,
      );
    }
    return const PumpRunDecision(
      start: false,
      reject: false,
      alreadyRunningSameCommand: false,
      status: 'accepted',
      durationMs: 0,
    );
  }
  if (isWaterPump && !rainNodeOnline) {
    return const PumpRunDecision(
      start: false,
      reject: true,
      alreadyRunningSameCommand: false,
      status: 'rejected',
      durationMs: 0,
    );
  }
  if (pumpActive && activeRequestId == requestId && requestId.isNotEmpty) {
    return const PumpRunDecision(
      start: false,
      reject: false,
      alreadyRunningSameCommand: true,
      status: 'running',
      durationMs: 0,
    );
  }
  if (pumpActive) {
    return const PumpRunDecision(
      start: false,
      reject: true,
      alreadyRunningSameCommand: false,
      status: 'rejected',
      durationMs: 0,
    );
  }
  if (!canStartActuatorAlongside(actuator, activeActuators)) {
    return const PumpRunDecision(
      start: false,
      reject: true,
      alreadyRunningSameCommand: false,
      status: 'rejected',
      durationMs: 0,
    );
  }

  return PumpRunDecision(
    start: true,
    reject: false,
    alreadyRunningSameCommand: false,
    status: 'running',
    durationMs: timedPumpDurationMs(actuator),
  );
}

/// Rollover-safe equivalent of `(long)(now - stopAt) >= 0` on 32-bit millis.
bool millisDeadlineReached(int nowMs, int stopAtMs) {
  final now = nowMs.toUnsigned(32);
  final stopAt = stopAtMs.toUnsigned(32);
  final delta = (now - stopAt).toUnsigned(32);
  return delta < 0x80000000;
}
