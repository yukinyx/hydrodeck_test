import 'package:flutter/material.dart';

const String termsOfUseVersion = '2026-11-06';
const String privacyPolicyVersion = '2026-11-06';

const String termsOfUseDocument = r'''# HydroDeck Terms of Use
**Last updated:** 6 November 2026

## 1. About HydroDeck
HydroDeck is a hydroponics system and mobile application developed as a student project by fourth-year Network Technology students from the College of Informatics and Computing Sciences, Batangas State University–Malvar Campus.

The app is intended to help users view system readings and planting history, receive relevant notifications, and control supported HydroDeck equipment. Unless Batangas State University confirms otherwise, HydroDeck should be described as a student project and not as an official university service or product.

## 2. Agreement to these Terms
By creating an account or using HydroDeck, you agree to these Terms of Use and the HydroDeck Privacy Policy. If you do not agree, do not use the app.

## 3. Accounts and security
You must provide accurate information when creating or updating an account. Keep your sign-in credentials and app PIN private. You are responsible for activity through your account unless it resulted from unauthorized access that you have reported to the project team.

The app uses Firebase Authentication for email-and-password sign-in. Account verification and recovery may use email. Do not send your password or app PIN to the HydroDeck team.

## 4. Proper use
You may use HydroDeck only with systems and networks you own or are authorized to operate. You agree not to:

- Attempt to bypass account, device, or system security.
- Control equipment without authorization.
- Interfere with HydroDeck’s operation or another user’s access.
- Use the app for unlawful activity or in a way that creates an unsafe condition or could damage equipment.

## 5. Readings, controls, and growing risks
HydroDeck displays readings such as pH, TDS, water temperature, grow-bed water level, reservoir status, and actuator state. It can also send commands for supported pumps and grow lights. The system includes pH-based pump control.

Readings may be inaccurate, delayed, incomplete, or unavailable. Commands and notifications may fail, be delayed, or not be confirmed. The system depends on sensors, ESP32 devices, power, Wi-Fi, internet access, the app, and cloud services.

HydroDeck is an aid and is not a guarantee that plants or equipment will remain in a safe condition. Check plants, water levels, nutrient conditions, and equipment directly and regularly. Do not rely on the app as the only means of identifying a problem or protecting a crop.

## 6. Hardware and physical safety
HydroDeck uses sensor readings and ESP32 hardware. The project team does not guarantee that sensors are calibrated, precise, or suitable for every growing condition. Users should verify important readings and maintain equipment appropriately.

Pump, grow-light, and pH-control features can cause physical equipment to operate. You are responsible for ensuring that the system is installed and wired correctly, relays and connected equipment are suitable for their loads, and water and electrical components are used safely. Monitor the physical system; an app command or displayed status does not by itself prove that a device has operated safely.

Turn off or unplug the system before cleaning or handling components near electrical parts. Do not handle electrical parts with wet hands.

## 7. Wi-Fi and device connections
During Wi-Fi setup, the app sends the network name and password you enter to the ESP32 over the local setup connection. The ESP32 stores those credentials so it can reconnect to the network. Enter credentials only for networks you are authorized to use.

The app communicates with the system through local Wi-Fi and cloud services. The ESP32 boards communicate with each other through ESP-NOW. Local control and cloud features may be unavailable if a device, network, or service is disconnected or experiencing an outage.

## 8. User-provided settings and system data
You retain whatever rights you have in information and settings you provide, such as your account information and configured pH limits. You allow the HydroDeck project to process and store those items only as reasonably needed to operate the app and system, display readings and planting history, synchronize records, and provide support.

The code reviewed does not show HydroDeck using account-linked readings or settings to train machine-learning models or serve targeted advertisements. Any future use of this information for a new purpose will be disclosed and handled in accordance with applicable law.

## 9. Availability and changes
HydroDeck is a developing student project. Features, device compatibility, and availability may change. The project team will make reasonable efforts to explain material changes through the app or another appropriate channel.

## 10. Disclaimer and limitation of liability
HydroDeck is provided without a guarantee that every sensor reading, connection, notification, or control command will be uninterrupted or error-free.

To the extent permitted by Philippine law, the project team is not responsible for indirect or consequential losses, including lost yield, damaged plants, or lost income, arising from circumstances such as sensor errors, equipment or power failure, Wi-Fi or internet interruptions, app or cloud-service downtime, or missed or delayed alerts.

Nothing in these Terms excludes liability that cannot legally be excluded or limits rights and remedies provided by applicable law. In particular, this section is not a waiver of future fraud claims or other non-waivable rights under Philippine law. See the Civil Code of the Philippines, including Articles 1170–1173. [Republic Act No. 386]

## 11. Third-party services
HydroDeck relies on third-party services, including Firebase for account authentication and cloud data and an email service for verification or one-time codes. Those services are subject to their own terms and privacy practices.

## 12. Account deletion
You may request account deletion through the app, where available, or by contacting the HydroDeck team. The app records a pending deletion request and a scheduled date seven days later. The app signing you out does not itself confirm that the Firebase account and all associated data have been deleted. See the Privacy Policy for details.

## 13. Philippine law
These Terms are governed by the laws of the Republic of the Philippines, subject to any mandatory legal rights or remedies that apply.

## 14. Contact
For questions about these Terms or HydroDeck, contact:

**HydroDeck Project Team**
College of Informatics and Computing Sciences
Batangas State University–Malvar Campus
Email: [**hydrodecknt@gmail.com**]''';

const String privacyPolicyDocument = r'''# HydroDeck Privacy Policy
**Last updated:** 6 November 2026

## 1. Who is responsible for your information?
HydroDeck is a student project developed by fourth-year Network Technology students from the College of Informatics and Computing Sciences, Batangas State University–Malvar Campus.

**Official Personal Information Controller:** Hydrodeck Project Team

The HydroDeck Project Team can receive privacy questions at [**hydrodecknt@gmail.com**]'. 

## 2. Information the app uses
Depending on the features you use, HydroDeck may process:

- **Account information:** email address, phone number, Firebase account identifier, account creation time, and account status.
- **Sign-in and verification information:** email/password sign-in is handled through Firebase Authentication. Email verification, one-time codes, and password recovery may use email. The app does not need to store your Firebase password in your user profile.
- **Hydroponics readings:** pH, TDS, water temperature, grow-bed water levels, reservoir level and status, and reading timestamps.
- **System and planting information:** planting batch/run numbers and dates, sensor history, pump and grow-light states, command status, and device connection or “last seen” status.
- **Settings:** pH thresholds, selected device IP address, planting-session information, and local app-security preferences.
- **Wi-Fi setup information:** the network name and password you enter are sent over the local setup connection to the ESP32. The ESP32 stores those credentials so it can reconnect to the network. The app code reviewed does not show Wi-Fi credentials being saved to your Firebase profile.
- **Device permissions and connection information:** Wi-Fi access and scanning permissions may be used to find or connect to HydroDeck devices. Notifications may be used for system alerts. If you enable biometric authentication, the operating system handles the biometric check; HydroDeck does not receive your biometric template.
The app stores some settings and history in a local database on your device. The code also stores a configured app PIN locally. This policy does not claim that the local PIN is encrypted.

The Android app requests Wi-Fi-related, notification, biometric, and background-service permissions to support its features. The code reviewed does not show the app collecting precise GPS coordinates, accessing contacts, or using an advertising or analytics SDK. Wi-Fi scanning may reveal nearby network names while you use the network setup feature.

## 3. Why information is used
HydroDeck uses information as needed to:

- Create and manage your account and support sign-in, verification, and recovery.
- Display readings, system status, and planting history.
- Send requested pump or grow-light commands and report their status.
- Apply configured settings, including pH thresholds, and provide relevant notifications.
- Save and synchronize planting records and readings.
- Troubleshoot app, device, and connection problems.
- Receive and respond to account and privacy requests.
Information necessary for requested account and system features is processed to provide those features. Optional information or permissions are requested when needed for a feature. The official Personal Information Controller should confirm and document the lawful basis for each processing activity.

## 4. Where information is stored and who may receive it
Account information and cloud history are processed using Firebase services, including Firebase Authentication, Realtime Database, and Cloud Firestore. Some app settings and records may also remain in local storage on your phone. Wi-Fi credentials are sent to and stored by the ESP32 for network reconnection. Email verification and one-time codes are delivered through the email service configured for the project.

Information may be accessible to authorized project administrators and service providers needed to operate HydroDeck. Cloud storage and processing locations depend on the project’s Firebase configuration and the providers’ services. The project team should confirm the configured data regions and applicable safeguards before publication.

The code reviewed does not show HydroDeck selling personal information, serving targeted advertising, or using account-linked telemetry to train machine-learning models.

## 5. Wi-Fi credentials and device communication
The app sends Wi-Fi setup details to the ESP32 through its local setup connection. The reviewed provisioning code uses a local HTTP endpoint and stores the credentials on the ESP32. Do not enter credentials for a network you are not authorized to use.

The app uses local Wi-Fi communication and cloud services. The two ESP32 boards communicate with each other through ESP-NOW. The code reviewed does not show Bluetooth communication. Readings are identified as TDS in the app; the app does not label them as EC.

## 6. Retention and deletion
The project keeps information only for as long as needed for the purposes described in this policy, subject to applicable legal requirements.

**Retention schedule:** 365 days for account and its associated readings, history, and settings. The project team should confirm that the retention schedule is implemented in the app and cloud services.

You may request deletion by using the app’s deletion feature, where available, or by emailing [**hydrodecknt@gmail.com**]. The current app asks for email verification, records a pending deletion request with a date seven days later, and signs you out. The app code alone does not confirm that an automatic process deletes the Firebase Authentication account and all related records on that date. The responsible project administrator must process the request and confirm completion.

Uninstalling the app may remove app-local information from the phone, but it does not by itself delete cloud information or credentials saved on the ESP32.

## 7. Security
The project uses account authentication, Firebase access rules, local storage, and device communications. No internet-connected or wireless system can be guaranteed completely secure. Keep your account credentials and home Wi-Fi password private, secure your phone, and use HydroDeck only with authorized devices and networks.

The app stores a configured app PIN in its local database. The project team should review and improve PIN protection before release. This policy does not claim that the PIN or all locally stored records are encrypted.

## 8. Your privacy rights and choices
Under the Philippine Data Privacy Act, you may have rights to be informed, access and correct personal information, object to certain processing, request erasure or blocking where applicable, and seek data portability or file a complaint, subject to legal conditions. [RA 10173] · [NPC data-subject rights]

To make a request, email [**hydrodecknt@gmail.com**] from your registered email address and describe the request. Do not include your password or app PIN. The team may ask for reasonable verification before acting.

You may decline optional permissions or information, but Wi-Fi setup, notifications, biometric sign-in, cloud history, or other features may not work without the required information or permission.

If you believe your privacy rights have not been addressed, you may contact the National Privacy Commission in accordance with its procedures.

## 9. Children
HydroDeck is an educational hydroponics project. If a child uses the app, a parent, guardian, or responsible school representative should supervise use. The project team should confirm applicable consent and school requirements before collecting information from children.

## 10. Changes to this Policy
This Policy may be updated if HydroDeck’s features or data practices change. The current version should show its effective date and be available in the app or another accessible location.

## 11. Contact
For privacy requests or questions, contact:

**HydroDeck Project Team**
College of Informatics and Computing Sciences
Batangas State University–Malvar Campus
Email: [**hydrodecknt@gmail.com**]'

**Official Personal Information Controller / Data Protection Officer:** Hydrodeck Project Team''';

class PolicyDocumentScreen extends StatelessWidget {
  final String title;
  final String document;

  const PolicyDocumentScreen({
    super.key,
    required this.title,
    required this.document,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          for (final line in document.split('\n')) _buildLine(line),
        ],
      ),
    );
  }

  Widget _buildLine(String line) {
    if (line.isEmpty) return const SizedBox(height: 10);
    if (line.startsWith('# ')) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          line.substring(2),
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      );
    }
    if (line.startsWith('## ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Text(
          line.substring(3),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      );
    }
    if (line.startsWith('- ')) {
      return Padding(
        padding: const EdgeInsets.only(left: 8, bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('•  '),
            Expanded(child: SelectableText(_plainText(line.substring(2)))),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SelectableText(
        _plainText(line),
        style: const TextStyle(height: 1.45),
      ),
    );
  }

  String _plainText(String value) {
    return value
        .replaceAllMapped(
          RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
          (match) => '${match.group(1)} (${match.group(2)})',
        )
        .replaceAll('**', '');
  }
}

void openTermsOfUse(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (context) => const PolicyDocumentScreen(
        title: 'Terms of Use',
        document: termsOfUseDocument,
      ),
    ),
  );
}

void openPrivacyPolicy(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (context) => const PolicyDocumentScreen(
        title: 'Privacy Policy',
        document: privacyPolicyDocument,
      ),
    ),
  );
}

class PolicySettingsSection extends StatelessWidget {
  const PolicySettingsSection({super.key, required this.onContactSupport});

  final VoidCallback onContactSupport;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Legal & Support',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Terms of Use'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openTermsOfUse(context),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Privacy Policy'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openPrivacyPolicy(context),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.support_agent_outlined),
                title: const Text('Contact Customer Support'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onContactSupport,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget policyConsentText({
  required VoidCallback onTermsTap,
  required VoidCallback onPrivacyTap,
}) {
  final linkStyle = TextButton.styleFrom(
    foregroundColor: const Color(0xFF168A43),
    padding: EdgeInsets.zero,
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    textStyle: const TextStyle(
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
    ),
  );
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('By signing up, you agree to the '),
      TextButton(
        key: const ValueKey('signup-terms-link'),
        onPressed: onTermsTap,
        style: linkStyle,
        child: const Text('Terms of Use'),
      ),
      const Text(' and '),
      TextButton(
        key: const ValueKey('signup-privacy-link'),
        onPressed: onPrivacyTap,
        style: linkStyle,
        child: const Text('Privacy Policy'),
      ),
      const Text('.'),
    ],
  );
}
