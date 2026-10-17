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
