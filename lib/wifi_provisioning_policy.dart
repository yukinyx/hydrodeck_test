// Map stable device status codes without guessing the underlying cause.
String wifiProvisioningMessage(String? code) => switch (code) {
  'testing' => 'The ESP32 is testing the Wi-Fi connection...',
  'connected' => 'Connected to Wi-Fi successfully.',
  'network_unavailable' =>
    'Could not find that Wi-Fi network. Check the name and use a 2.4 GHz network.',
  'authentication_failed' =>
    'Could not connect—check the Wi-Fi password. The ESP32 reported an authentication failure.',
  'connection_failed' =>
    'The ESP32 found the network but could not connect. Check the network settings and try again.',
  'timeout' =>
    'The Wi-Fi connection timed out. Check that the network is available and try again.',
  'missing_credentials' => 'Enter both the Wi-Fi name and password.',
  'invalid_credentials' => 'The Wi-Fi name or password is not valid.',
  _ => 'The ESP32 could not determine the Wi-Fi connection result. Try again.',
};

bool isWifiProvisioningPending(String? code) => code == 'testing';
