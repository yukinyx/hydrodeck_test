// Map stable device status codes without guessing the underlying cause.
String wifiProvisioningMessage(String? code) => switch (code) {
  'received' => 'Credentials received. Checking the Wi-Fi network...',
  'scanning' => 'The ESP32 is checking whether the Wi-Fi network is available...',
  'testing' => 'The ESP32 is testing the Wi-Fi connection...',
  'rain_pending' =>
    'MAIN is testing Wi-Fi and waiting for RAIN to confirm credential storage...',
  'rain_unconfirmed' =>
    'MAIN processed the Wi-Fi details, but RAIN did not confirm that it stored them. Check that RAIN is online and retry.',
  'rain_rejected' =>
    'MAIN processed the Wi-Fi details, but RAIN rejected them. Check the network details and retry.',
  'connected' => 'Connected to Wi-Fi successfully.',
  'network_unavailable' =>
    'The ESP32 could not find that Wi-Fi network. Check the name and try again.',
  'authentication_failed' =>
    'The ESP32 failed to connect. Check the Wi-Fi password and try again.',
  'connection_failed' =>
    'The ESP32 could not connect to Wi-Fi. Please check the network details and try again.',
  'timeout' =>
    'The ESP32 could not connect to Wi-Fi. Please check the network details and try again.',
  'busy' =>
    'The ESP32 is already processing a Wi-Fi setup request. Retry when it is finished.',
  'missing_credentials' => 'Enter both the Wi-Fi name and password.',
  'invalid_credentials' => 'The Wi-Fi name or password is not valid.',
  _ => 'The ESP32 could not determine the Wi-Fi connection result. Try again.',
};

bool isWifiProvisioningPending(String? code) =>
    code == 'received' ||
    code == 'scanning' ||
    code == 'testing' ||
    code == 'rain_pending';

bool isWifiProvisioningAccepted(String? code) =>
    isWifiProvisioningPending(code) ||
    code == 'rain_unconfirmed' ||
    code == 'rain_rejected' ||
    code == 'connected' ||
    code == 'network_unavailable' ||
    code == 'authentication_failed' ||
    code == 'connection_failed' ||
    code == 'timeout' ||
    code == 'missing_credentials' ||
    code == 'invalid_credentials';

bool isWifiProvisioningFinal(String? code) =>
    isWifiProvisioningAccepted(code) && !isWifiProvisioningPending(code);

String completedProvisioningMessage({
  required String result,
  required bool disconnectedFromHotspot,
}) {
  final message = wifiProvisioningMessage(result);
  if (disconnectedFromHotspot) return message;
  return '$message Switch your phone to the home Wi-Fi network manually.';
}
