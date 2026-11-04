const Set<String> commandAckStatuses = {
  'accepted',
  'running',
  'completed',
  'rejected',
  'timed_out',
};

const Set<String> terminalCommandAckStatuses = {
  'completed',
  'rejected',
  'timed_out',
};

bool isValidCommandAckStatus(String? status) =>
    status != null && commandAckStatuses.contains(status);

bool isTerminalCommandAckStatus(String? status) =>
    status != null && terminalCommandAckStatuses.contains(status);

bool shouldReleasePendingCommand({String? status, bool timedOut = false}) =>
  timedOut || isTerminalCommandAckStatus(status);

bool shouldClearPendingAfterDispatch({
  required bool localAccepted,
  required bool firebaseQueued,
}) =>
    !localAccepted && !firebaseQueued;

bool isConfirmedWaterPumpOnAck(String actuator, String? status) =>
  actuator.startsWith('waterPump') && status == 'running';

// Map device command identifiers and outcomes into readable control messages.
String commandActuatorLabel(String actuator) {
  if (actuator == 'growLight') return 'Grow light';
  final bed = actuator.endsWith('2') ? '2' : '1';
  if (actuator.startsWith('waterPump')) return 'Water pump — grow bed $bed';
  if (actuator.startsWith('phUp')) return 'pH up pump — grow bed $bed';
  if (actuator.startsWith('phDown')) return 'pH down pump — grow bed $bed';
  if (actuator.startsWith('nutrient')) {
  return 'Nutrient pump — grow bed $bed';
  }
  return actuator;
}

String friendlyCommandFailureMessage({
  required String status,
  String? reason,
}) {
  if (status == 'rejected') {
  return switch (reason?.trim()) {
    'rain_node_offline' => 'The rainwater unit is offline.',
    'rain_node_no_confirm' =>
      'The rainwater unit did not confirm the pump command.',
    'max_run' => 'The pump reached its maximum run time.',
    _ => 'The ESP32 rejected this command.',
  };
  }
  if (status == 'timed_out') {
  return 'The command timed out before the ESP32 confirmed it.';
  }
  if (status == 'offline') {
  return 'The ESP32 is offline or unreachable. Check its connection and retry.';
  }
  if (status == 'unconfirmed') {
  return 'The command was accepted, but its completion was not confirmed.';
  }
  return 'The command could not be confirmed. Please try again.';
}
