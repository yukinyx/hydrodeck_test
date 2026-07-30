import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:local_auth/local_auth.dart';

// --- LOCAL DATABASE SERVICE ---
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database?> get database async {
    if (kIsWeb) return null; // Web bypass to avoid sqflite runtime exceptions
    if (_database != null) return _database!;
    try {
      _database = await _initDB('hydrodeck.db');
      return _database!;
    } catch (_) {
      return null;
    }
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 3,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE settings_config (
              id INTEGER PRIMARY KEY,
              minPh REAL NOT NULL,
              maxPh REAL NOT NULL
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE app_security (
              id INTEGER PRIMARY KEY,
              customPin TEXT,
              isBiometricsEnabled INTEGER NOT NULL
            )
          ''');
        }
      },
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE historical_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        pH REAL NOT NULL,
        temperature TEXT NOT NULL,
        waterLevel TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE planting_history (
        batchNumber INTEGER PRIMARY KEY,
        startDate TEXT NOT NULL,
        endDate TEXT NOT NULL,
        totalDays INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE active_session (
        id INTEGER PRIMARY KEY,
        startDate TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE active_ip (
        id INTEGER PRIMARY KEY,
        ip TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE settings_config (
        id INTEGER PRIMARY KEY,
        minPh REAL NOT NULL,
        maxPh REAL NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE app_security (
        id INTEGER PRIMARY KEY,
        customPin TEXT,
        isBiometricsEnabled INTEGER NOT NULL
      )
    ''');
  }

  // Security Configuration Queries
  Future<void> saveSecurityConfig({String? customPin, required bool isBiometricsEnabled}) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert(
      'app_security',
      {
        'id': 1,
        'customPin': customPin,
        'isBiometricsEnabled': isBiometricsEnabled ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getSecurityConfig() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query('app_security', where: 'id = ?', whereArgs: [1]);
    if (result.isNotEmpty) {
      return {
        'customPin': result.first['customPin'] as String?,
        'isBiometricsEnabled': (result.first['isBiometricsEnabled'] as int) == 1,
      };
    }
    return null;
  }

  // Historical Logs Queries
  Future<void> insertLog(HistoricalData log) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert('historical_logs', {
      'timestamp': log.timestamp.toIso8601String(),
      'pH': log.pH,
      'temperature': log.temperature,
      'waterLevel': log.waterLevel,
    });
  }

  Future<List<HistoricalData>> getLogs() async {
    final db = await instance.database;
    if (db == null) return [];
    final result = await db.query('historical_logs', orderBy: 'timestamp DESC');
    return result.map((json) => HistoricalData(
      timestamp: DateTime.parse(json['timestamp'] as String),
      pH: (json['pH'] as num).toDouble(),
      temperature: json['temperature'] as String,
      waterLevel: json['waterLevel'] as String,
    )).toList();
  }

  // Planting Runs History Queries
  Future<void> insertPlantingRecord(PlantingRecord record) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert('planting_history', {
      'batchNumber': record.batchNumber,
      'startDate': record.startDate.toIso8601String(),
      'endDate': record.endDate.toIso8601String(),
      'totalDays': record.totalDays,
    });
  }

  Future<List<PlantingRecord>> getPlantingHistory() async {
    final db = await instance.database;
    if (db == null) return [];
    final result = await db.query('planting_history', orderBy: 'batchNumber ASC');
    return result.map((json) => PlantingRecord(
      batchNumber: json['batchNumber'] as int,
      startDate: DateTime.parse(json['startDate'] as String),
      endDate: DateTime.parse(json['endDate'] as String),
      totalDays: json['totalDays'] as int,
    )).toList();
  }

  // Session State Persistence
  Future<void> saveActiveSession(DateTime startDate) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert(
      'active_session',
      {'id': 1, 'startDate': startDate.toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<DateTime?> getActiveSession() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query('active_session', where: 'id = ?', whereArgs: [1]);
    if (result.isNotEmpty) {
      return DateTime.parse(result.first['startDate'] as String);
    }
    return null;
  }

  Future<void> clearActiveSession() async {
    final db = await instance.database;
    if (db == null) return;
    await db.delete('active_session', where: 'id = ?', whereArgs: [1]);
  }

  // Saved Target IP Persistence
  Future<void> saveActiveIp(String ip) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert(
      'active_ip',
      {'id': 1, 'ip': ip},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> getActiveIp() async {
    final db = await instance.database;
    if (db == null) return "hydrodeck.local";
    final result = await db.query('active_ip', where: 'id = ?', whereArgs: [1]);
    if (result.isNotEmpty) {
      return result.first['ip'] as String;
    }
    return "hydrodeck.local";
  }

  // Settings Limits Persistence
  Future<void> saveSettingsConfig(double minPh, double maxPh) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert(
      'settings_config',
      {'id': 1, 'minPh': minPh, 'maxPh': maxPh},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, double>> getSettingsConfig() async {
    final db = await instance.database;
    if (db == null) return {'minPh': 5.5, 'maxPh': 6.8};
    final result = await db.query('settings_config', where: 'id = ?', whereArgs: [1]);
    if (result.isNotEmpty) {
      return {
        'minPh': (result.first['minPh'] as num).toDouble(),
        'maxPh': (result.first['maxPh'] as num).toDouble(),
      };
    }
    return {'minPh': 5.5, 'maxPh': 6.8};
  }
}

// --- NOTIFICATION SERVICE ---
class NotificationHelper {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    if (kIsWeb) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings settings =
        InitializationSettings(android: androidSettings);

    await _notificationsPlugin.initialize(settings);

    _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> showPhAlertNotification(double ph) async {
    if (kIsWeb) return;

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'ph_alerts_channel',
      'pH Level Alerts',
      channelDescription: 'Notifications for critical pH level limits',
      importance: Importance.max,
      priority: Priority.high,
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      '⚠️ Critical pH Alert',
      'pH level has remained in critical range (${ph.toStringAsFixed(2)}) for over 20 seconds!',
      details,
    );
  }
}

// --- BACKGROUND SERVICE MANAGEMENT ---
Future<void> initializeBackgroundService() async {
  if (kIsWeb) return;

  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'hydrodeck_bg_service',
    'Hydrodeck Background Engine',
    description: 'Keeps ESP32 connection live and records metrics continuous logs.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundServiceStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'hydrodeck_bg_service',
      initialNotificationTitle: 'Hydrodeck Service Active',
      initialNotificationContent: 'Monitoring ESP32 and logging sensors in background...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onBackgroundServiceStart,
    ),
  );

  await service.startService();
}

@pragma('vm:entry-point')
void onBackgroundServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  String targetIp = "hydrodeck.local";
  double lastPh = 7.0;
  String lastTemp = "25.0°C";
  String lastWater = "low";
  bool isConnected = false;

  bool isAppClosed = false; 
  bool isPlantingActive = false;

  double minPhThreshold = 5.5;
  double maxPhThreshold = 6.8;

  DateTime? criticalPhStart;
  DateTime? lastAlertTime;

  try {
    targetIp = await DatabaseHelper.instance.getActiveIp();
    final limits = await DatabaseHelper.instance.getSettingsConfig();
    minPhThreshold = limits['minPh']!;
    maxPhThreshold = limits['maxPh']!;
    
    final activeSession = await DatabaseHelper.instance.getActiveSession();
    isPlantingActive = activeSession != null;

    final logs = await DatabaseHelper.instance.getLogs();
    if (logs.isNotEmpty) {
      lastPh = logs.first.pH;
      lastTemp = logs.first.temperature;
      lastWater = logs.first.waterLevel == "Water full" ? "full" : "low";
    }
  } catch (_) {}

  service.on('setPlantingState').listen((event) {
    if (event != null && event['active'] != null) {
      isPlantingActive = event['active'] as bool;
    }
  });

  service.on('updateIp').listen((event) {
    if (event != null && event['ip'] != null) {
      targetIp = event['ip'];
      DatabaseHelper.instance.saveActiveIp(targetIp);
    }
  });

  service.on('updateLimits').listen((event) {
    if (event != null) {
      if (event['minPh'] != null) minPhThreshold = (event['minPh'] as num).toDouble();
      if (event['maxPh'] != null) maxPhThreshold = (event['maxPh'] as num).toDouble();
      DatabaseHelper.instance.saveSettingsConfig(minPhThreshold, maxPhThreshold);
    }
  });

  service.on('appState').listen((event) {
    if (event != null && event['state'] != null) {
      isAppClosed = (event['state'] == 'background');
    }
  });

  Timer.periodic(const Duration(seconds: 2), (timer) async {
    // Only connect and poll ESP32 if planting has been started
    if (!isPlantingActive) {
      service.invoke('telemetryUpdate', {
        'isConnected': false,
        'ip': targetIp,
        'ph': lastPh,
        'temp': lastTemp,
        'water': lastWater,
      });
      return;
    }

    final List<String> candidateHosts = [
      targetIp,
      "hydrodeck.local",
      "192.168.1.100",
      "192.168.0.100",
      "10.0.2.2"
    ];

    bool found = false;
    for (String host in candidateHosts) {
      try {
        final res = await http.get(Uri.parse('http://$host/status')).timeout(const Duration(milliseconds: 1500));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data['ph'] != null) {
            lastPh = (data['ph'] is num) ? (data['ph'] as num).toDouble() : lastPh;
          }
          if (data['temp'] != null && data['temp'] != 0.0) {
            lastTemp = "${data['temp']}°C";
          }
          lastWater = data['water'] ?? lastWater;
          
          targetIp = host;
          isConnected = true;
          found = true;
          break;
        }
      } catch (_) {}
    }

    if (!found) {
      isConnected = false;
    }

    bool isCritical = (lastPh < minPhThreshold || lastPh > maxPhThreshold);

    if (isCritical) {
      criticalPhStart ??= DateTime.now();
      final durationInCritical = DateTime.now().difference(criticalPhStart!).inSeconds;

      if (durationInCritical >= 20) {
        bool shouldNotify = false;
        if (lastAlertTime == null) {
          shouldNotify = true;
        } else if (DateTime.now().difference(lastAlertTime!).inSeconds >= 20) {
          shouldNotify = true;
        }

        if (shouldNotify && isAppClosed) {
          NotificationHelper.showPhAlertNotification(lastPh);
          lastAlertTime = DateTime.now();
        }
      }
    } else {
      criticalPhStart = null;
      lastAlertTime = null;
    }

    service.invoke('telemetryUpdate', {
      'isConnected': isConnected,
      'ip': targetIp,
      'ph': lastPh,
      'temp': lastTemp,
      'water': lastWater,
    });
  });

  Timer.periodic(const Duration(seconds: 20), (timer) async {
    if (!isPlantingActive) return;

    final snapshot = HistoricalData(
      timestamp: DateTime.now(),
      pH: lastPh,
      temperature: lastTemp,
      waterLevel: lastWater == "full" ? "Water full" : "Needs water",
    );

    try {
      await DatabaseHelper.instance.insertLog(snapshot);
      service.invoke('newSnapshotLogged', {
        'timestamp': snapshot.timestamp.toIso8601String(),
        'pH': snapshot.pH,
        'temperature': snapshot.temperature,
        'waterLevel': snapshot.waterLevel,
      });
    } catch (_) {}
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    await NotificationHelper.init();
    await initializeBackgroundService();
  }
  runApp(const HydrodeckApp());
}

class HydrodeckApp extends StatefulWidget {
  const HydrodeckApp({super.key});

  @override
  State<HydrodeckApp> createState() => _HydrodeckAppState();
}

class _HydrodeckAppState extends State<HydrodeckApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      FlutterBackgroundService().invoke('appState', {'state': 'foreground'});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      FlutterBackgroundService().invoke('appState', {'state': 'background'});
    } else if (state == AppLifecycleState.resumed) {
      FlutterBackgroundService().invoke('appState', {'state': 'foreground'});
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hydrodeck',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF9F9F9),
        fontFamily: 'Sans-Serif',
        primaryColor: const Color(0xFF2DC867),
      ),
      home: const MainGatekeeper(),
    );
  }
}

class HistoricalData {
  final DateTime timestamp;
  final double pH;
  final String temperature;
  final String waterLevel;

  HistoricalData({
    required this.timestamp,
    required this.pH,
    required this.temperature,
    required this.waterLevel,
  });
}

class PlantingRecord {
  final int batchNumber;
  final DateTime startDate;
  final DateTime endDate;
  final int totalDays;

  PlantingRecord({
    required this.batchNumber,
    required this.startDate,
    required this.endDate,
    required this.totalDays,
  });
}

// --- INITIAL APP GATEKEEPER & AUTHENTICATION SCREEN ---
class PinSetupScreen extends StatefulWidget {
  final VoidCallback onAuthenticated;

  const PinSetupScreen({super.key, required this.onAuthenticated});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  static const String _defaultPin = "6967";
  
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _customPinController = TextEditingController();
  final LocalAuthentication _localAuth = LocalAuthentication();

  int _failedAttempts = 0;
  int _lockoutTimeRemaining = 0;
  Timer? _lockoutTimer;

  bool _isPinVerified = false;
  bool _enableBiometrics = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    _customPinController.dispose();
    _lockoutTimer?.cancel();
    super.dispose();
  }

  void _startLockoutTimer() {
    setState(() {
      _lockoutTimeRemaining = 60;
    });

    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_lockoutTimeRemaining > 1) {
        setState(() {
          _lockoutTimeRemaining--;
        });
      } else {
        timer.cancel();
        setState(() {
          _failedAttempts = 0;
          _lockoutTimeRemaining = 0;
          _errorMessage = null;
        });
      }
    });
  }

  void _verifyPin() {
    if (_lockoutTimeRemaining > 0) return;

    final enteredPin = _pinController.text.trim();

    if (enteredPin == _defaultPin) {
      setState(() {
        _isPinVerified = true;
        _errorMessage = null;
      });
    } else {
      _failedAttempts++;
      if (_failedAttempts >= 5) {
        _startLockoutTimer();
      } else {
        setState(() {
          _errorMessage = "Invalid PIN. ${5 - _failedAttempts} attempts left.";
        });
      }
      _pinController.clear();
    }
  }

  Future<void> _handleBiometricToggle(bool value) async {
    if (value) {
      try {
        bool canCheck = await _localAuth.canCheckBiometrics || await _localAuth.isDeviceSupported();
        if (!canCheck) {
          setState(() {
            _errorMessage = "Biometrics are not supported or available on this device.";
            _enableBiometrics = false;
          });
          return;
        }

        bool authenticated = await _localAuth.authenticate(
          localizedReason: 'Please authenticate to enable biometric login for Hydrodeck',
          options: const AuthenticationOptions(
            stickyAuth: true,
            biometricOnly: true,
          ),
        );

        if (authenticated) {
          setState(() {
            _enableBiometrics = true;
            _errorMessage = null;
          });
        } else {
          setState(() {
            _enableBiometrics = false;
            _errorMessage = "Biometric setup was cancelled or failed.";
          });
        }
      } catch (e) {
        setState(() {
          _enableBiometrics = false;
          _errorMessage = "Error prompting OS biometrics: $e";
        });
      }
    } else {
      setState(() {
        _enableBiometrics = false;
      });
    }
  }

  Future<void> _completeSetup() async {
    String? newPin = _customPinController.text.trim();
    if (newPin.isEmpty) {
      newPin = null; 
    } else if (newPin.length != 4) {
      setState(() {
        _errorMessage = "Device PIN must be exactly 4 digits.";
      });
      return;
    }

    await DatabaseHelper.instance.saveSecurityConfig(
      customPin: newPin,
      isBiometricsEnabled: _enableBiometrics,
    );

    widget.onAuthenticated();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              const Text(
                'HYDRODECK',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2.0,
                  color: Color(0xFF232323),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                !_isPinVerified ? 'Initial Setup Authorization' : 'Preferences Setup',
                style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 40),

              if (!_isPinVerified) ...[
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(10),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.lock_outline, size: 48, color: Color(0xFF2DC867)),
                      const SizedBox(height: 16),
                      const Text(
                        'Enter 4-Digit Manual PIN',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Please enter the default factory PIN included in your device user manual.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _pinController,
                        enabled: _lockoutTimeRemaining == 0,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        obscureText: true,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 24, letterSpacing: 12, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          counterText: "",
                          hintText: "••••",
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: Color(0xFF2DC867), width: 2),
                          ),
                        ),
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                      if (_lockoutTimeRemaining > 0) ...[
                        const SizedBox(height: 12),
                        Text(
                          "Locked out. Retry in $_lockoutTimeRemaining seconds.",
                          style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _lockoutTimeRemaining > 0 ? null : _verifyPin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2DC867),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(25),
                          ),
                        ),
                        child: const Text('Verify PIN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(10),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(
                        child: Icon(Icons.phonelink_setup_rounded, size: 48, color: Color(0xFF2DC867)),
                      ),
                      const SizedBox(height: 16),
                      const Center(
                        child: Text(
                          'Personalize Access',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Device Custom PIN (Optional)',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Change PIN specifically for opening the app on this device. The manual PIN (6967) remains usable for setup resets.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _customPinController,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        obscureText: true,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 18, letterSpacing: 8, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          counterText: "",
                          hintText: "New PIN",
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFF2DC867), width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Divider(),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        activeColor: const Color(0xFF2DC867),
                        title: const Text('Enable Biometrics', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                        subtitle: const Text('Use Fingerprint or Face ID for fast unlocking', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        value: _enableBiometrics,
                        onChanged: _handleBiometricToggle,
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _completeSetup,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2DC867),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(25),
                          ),
                        ),
                        child: const Text('Save & Continue', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                    ],
                  ),
                ),
              ]
            ],
          ),
        ),
      ),
    );
  }
}

// --- UNLOCK AUTHENTICATION SCREEN FOR OPENING APP ---
class AppUnlockScreen extends StatefulWidget {
  final Map<String, dynamic> securityConfig;
  final VoidCallback onAuthenticated;

  const AppUnlockScreen({
    super.key,
    required this.securityConfig,
    required this.onAuthenticated,
  });

  @override
  State<AppUnlockScreen> createState() => _AppUnlockScreenState();
}

class _AppUnlockScreenState extends State<AppUnlockScreen> {
  final TextEditingController _pinController = TextEditingController();
  final LocalAuthentication _localAuth = LocalAuthentication();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.securityConfig['isBiometricsEnabled'] == true) {
      _tryBiometricAuth();
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _tryBiometricAuth() async {
    try {
      bool authenticated = await _localAuth.authenticate(
        localizedReason: 'Authenticate to access Hydrodeck',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
      if (authenticated) {
        widget.onAuthenticated();
      }
    } catch (_) {}
  }

  void _verifyPin() {
    final enteredPin = _pinController.text.trim();
    final customPin = widget.securityConfig['customPin'] as String?;

    bool isCorrect = false;
    if (customPin != null && customPin.isNotEmpty) {
      isCorrect = (enteredPin == customPin || enteredPin == "6967");
    } else {
      isCorrect = (enteredPin == "6967");
    }

    if (isCorrect) {
      widget.onAuthenticated();
    } else {
      setState(() {
        _errorMessage = "Incorrect PIN. Try again.";
      });
      _pinController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    bool bioEnabled = widget.securityConfig['isBiometricsEnabled'] == true;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.security, size: 64, color: Color(0xFF2DC867)),
                  const SizedBox(height: 16),
                  const Text(
                    'HYDRODECK LOCKED',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                  ),
                  const SizedBox(height: 8),
                  const Text('Enter your PIN to open the application', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _pinController,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    obscureText: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24, letterSpacing: 12, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      counterText: "",
                      hintText: "••••",
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(color: Color(0xFF2DC867), width: 2),
                      ),
                    ),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _verifyPin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2DC867),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                    ),
                    child: const Text('Unlock', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  if (bioEnabled) ...[
                    const SizedBox(height: 16),
                    IconButton(
                      iconSize: 40,
                      icon: const Icon(Icons.fingerprint, color: Color(0xFF2DC867)),
                      onPressed: _tryBiometricAuth,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainGatekeeper extends StatefulWidget {
  const MainGatekeeper({super.key});

  @override
  State<MainGatekeeper> createState() => _MainGatekeeperState();
}

class _MainGatekeeperState extends State<MainGatekeeper> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isPinVerified = false;
  bool _isFirstSetupRequired = false;
  Map<String, dynamic>? _securityConfig;

  bool _isPlantingActive = false;
  DateTime? _plantingStartDate;
  List<PlantingRecord> _pastPlantingRuns = [];
  
  String _activeEsp32Ip = "hydrodeck.local";
  StreamSubscription? _bgSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStoredSessionAndData();
    _listenToBackgroundService();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bgSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      if (mounted && !_isFirstSetupRequired) {
        setState(() {
          _isPinVerified = false;
        });
      }
    }
  }

  Future<void> _loadStoredSessionAndData() async {
    final activeDate = await DatabaseHelper.instance.getActiveSession();
    final pastRuns = await DatabaseHelper.instance.getPlantingHistory();
    final savedIp = await DatabaseHelper.instance.getActiveIp();
    final securityConfig = await DatabaseHelper.instance.getSecurityConfig();

    if (mounted) {
      setState(() {
        _pastPlantingRuns = pastRuns;
        _activeEsp32Ip = savedIp;
        _securityConfig = securityConfig;

        if (securityConfig == null) {
          _isFirstSetupRequired = true;
          _isPinVerified = false;
        } else {
          _isFirstSetupRequired = false;
          _isPinVerified = false; 
        }

        if (activeDate != null) {
          _plantingStartDate = activeDate;
          _isPlantingActive = true;
        }
        _isLoading = false;
      });
    }
  }

  void _listenToBackgroundService() {
    if (kIsWeb) return;
    _bgSubscription = FlutterBackgroundService().on('telemetryUpdate').listen((event) {
      if (event != null && event['ip'] != null && mounted) {
        setState(() {
          _activeEsp32Ip = event['ip'];
        });
      }
    });
  }

  void _startPlanting() async {
    final now = DateTime.now();
    await DatabaseHelper.instance.saveActiveSession(now);

    if (!kIsWeb) {
      FlutterBackgroundService().invoke('setPlantingState', {'active': true});
    }

    setState(() {
      _plantingStartDate = now;
      _isPlantingActive = true;
    });
  }

  void _endPlanting() async {
    if (_plantingStartDate == null) return;
    
    final now = DateTime.now();
    int totalDays = now.difference(_plantingStartDate!).inDays + 1;

    final newRecord = PlantingRecord(
      batchNumber: _pastPlantingRuns.length + 1,
      startDate: _plantingStartDate!,
      endDate: now,
      totalDays: totalDays,
    );

    await DatabaseHelper.instance.insertPlantingRecord(newRecord);
    await DatabaseHelper.instance.clearActiveSession();

    if (!kIsWeb) {
      FlutterBackgroundService().invoke('setPlantingState', {'active': false});
    }

    setState(() {
      _pastPlantingRuns.add(newRecord);
      _isPlantingActive = false;
      _plantingStartDate = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF2DC867)),
        ),
      );
    }

    if (_isFirstSetupRequired) {
      return PinSetupScreen(
        onAuthenticated: () async {
          final updatedConfig = await DatabaseHelper.instance.getSecurityConfig();
          setState(() {
            _securityConfig = updatedConfig;
            _isFirstSetupRequired = false;
            _isPinVerified = true;
          });
        },
      );
    }

    if (!_isPinVerified && _securityConfig != null) {
      return AppUnlockScreen(
        securityConfig: _securityConfig!,
        onAuthenticated: () {
          setState(() {
            _isPinVerified = true;
          });
        },
      );
    }

    if (!_isPlantingActive) {
      return StartPlantingScreen(
        onStart: _startPlanting,
        history: _pastPlantingRuns,
      );
    }
    return HydroponicsDashboard(
      startDate: _plantingStartDate!,
      onEndPlanting: _endPlanting,
      initialIp: _activeEsp32Ip,
    );
  }
}

class StartPlantingScreen extends StatelessWidget {
  final VoidCallback onStart;
  final List<PlantingRecord> history;

  const StartPlantingScreen({
    super.key,
    required this.onStart,
    required this.history,
  });

  void _showHistoryDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Planting Run History',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: history.isEmpty
                    ? const Center(
                        child: Text(
                          'No completed planting cycles yet.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: history.length,
                        itemBuilder: (context, index) {
                          final run = history[index];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              leading: const CircleAvatar(
                                backgroundColor: Color(0xFFE8F7ED),
                                child: Icon(Icons.eco, color: Color(0xFF2DC867)),
                              ),
                              title: Text(
                                'Batch #${run.batchNumber}',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                '${run.startDate.year}-${run.startDate.month}-${run.startDate.day} to ${run.endDate.year}-${run.endDate.month}-${run.endDate.day}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: Text(
                                '${run.totalDays} Days',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF2DC867),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text(
                  'HYDRODECK',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2.0,
                    color: Color(0xFF232323),
                  ),
                ),
                const SizedBox(height: 40),
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F7ED),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green.withAlpha(20),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      )
                    ],
                  ),
                  child: const Center(
                    child: Text(
                      '🥬',
                      style: TextStyle(fontSize: 70),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Hydroponic Lettuce',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 60),
                ElevatedButton(
                  onPressed: onStart,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2DC867),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    elevation: 2,
                  ),
                  child: const Text(
                    'Start Planting',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => _showHistoryDialog(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF2DC867),
                    side: const BorderSide(color: Color(0xFF2DC867), width: 1.5),
                    minimumSize: const Size(double.infinity, 56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: const Text(
                    'History',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HydroponicsDashboard extends StatefulWidget {
  final DateTime startDate;
  final VoidCallback onEndPlanting;
  final String initialIp;

  const HydroponicsDashboard({
    super.key,
    required this.startDate,
    required this.onEndPlanting,
    this.initialIp = "hydrodeck.local",
  });

  @override
  State<HydroponicsDashboard> createState() => _HydroponicsDashboardState();
}

class _HydroponicsDashboardState extends State<HydroponicsDashboard> {
  int _currentIndex = 0;

  late String _esp32Ip;
  late TextEditingController _ipController;
  
  String _connectionStatus = "Fetching...";
  
  String _lastValidWaterStatus = "low";
  String _lastValidWaterTemp = "25.0°C";
  double _lastValidPhValue = 7.00; 

  StreamSubscription? _telemetrySub;
  StreamSubscription? _snapshotSub;

  List<HistoricalData> _historyLogs = [];
  DateTime? _selectedFilterDate;

  bool _led1On = false;
  bool _led2On = false;

  double _minPhThreshold = 5.5;
  double _maxPhThreshold = 6.8;

  @override
  void initState() {
    super.initState();
    _esp32Ip = widget.initialIp;
    _ipController = TextEditingController(text: _esp32Ip);
    _loadStoredLogsAndSettings();
    _subscribeToBackgroundUpdates();
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _snapshotSub?.cancel();
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _loadStoredLogsAndSettings() async {
    final storedLogs = await DatabaseHelper.instance.getLogs();
    final config = await DatabaseHelper.instance.getSettingsConfig();
    if (mounted) {
      setState(() {
        _historyLogs = storedLogs;
        _minPhThreshold = config['minPh'] ?? 5.5;
        _maxPhThreshold = config['maxPh'] ?? 6.8;
        
        if (storedLogs.isNotEmpty) {
          _lastValidPhValue = storedLogs.first.pH;
          _lastValidWaterTemp = storedLogs.first.temperature;
          _lastValidWaterStatus = storedLogs.first.waterLevel == "Water full" ? "full" : "low";
        }
      });
    }
  }

  void _subscribeToBackgroundUpdates() {
    if (kIsWeb) return;
    _telemetrySub = FlutterBackgroundService().on('telemetryUpdate').listen((event) {
      if (event != null && mounted) {
        setState(() {
          _connectionStatus = (event['isConnected'] == true) ? "Connected" : "Disconnected";
          if (event['ph'] != null) {
            _lastValidPhValue = (event['ph'] as num).toDouble();
          }
          if (event['temp'] != null) {
            _lastValidWaterTemp = event['temp'];
          }
          if (event['water'] != null) {
            _lastValidWaterStatus = event['water'];
          }
          if (event['ip'] != null) {
            _esp32Ip = event['ip'];
          }
        });
      }
    });

    _snapshotSub = FlutterBackgroundService().on('newSnapshotLogged').listen((event) {
      if (event != null && mounted) {
        final newLog = HistoricalData(
          timestamp: DateTime.parse(event['timestamp']),
          pH: (event['pH'] as num).toDouble(),
          temperature: event['temperature'],
          waterLevel: event['waterLevel'],
        );
        setState(() {
          _historyLogs.insert(0, newLog);
        });
      }
    });
  }

  int _getElapsedPlantingDay(DateTime timestamp) {
    final startDay = DateTime(widget.startDate.year, widget.startDate.month, widget.startDate.day);
    final currentDay = DateTime(timestamp.year, timestamp.month, timestamp.day);
    return currentDay.difference(startDay).inDays + 1;
  }

  String _getProcessedWaterStatus() {
    return (_lastValidWaterStatus == "full") ? "Water full" : "Needs water";
  }

  String _formatDateTimeToReadable(DateTime dt) {
    const months = [
      "January", "February", "March", "April", "May", "June", 
      "July", "August", "September", "October", "November", "December"
    ];
    String month = months[dt.month - 1];
    int hour24 = dt.hour;
    String amPm = hour24 >= 12 ? "PM" : "AM";
    int hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    String minutes = dt.minute.toString().padLeft(2, '0');
    
    return "$month ${dt.day}, ${dt.year} $hour12:$minutes $amPm";
  }

  String _getDateCategoryHeader(DateTime dt) {
    int dayNum = _getElapsedPlantingDay(dt);
    if (dayNum >= 1) {
      return "Day $dayNum";
    }
    return "Pre-cycle Preparation";
  }

  Future<void> _toggleLed(String endpoint, int ledNumber) async {
    setState(() {
      if (ledNumber == 1) _led1On = !_led1On;
      if (ledNumber == 2) _led2On = !_led2On;
    });

    final Uri url = Uri.parse('http://$_esp32Ip/$endpoint');
    try {
      final response = await http.get(url).timeout(const Duration(seconds: 3));
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {});
      } else {
        setState(() {});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final String computedWaterLabel = _getProcessedWaterStatus();

    final List<Widget> screens = [
      _buildHomeScreen(computedWaterLabel),
      _buildControlScreen(),
      _buildDataScreen(),
      _buildSettingsScreen(),
    ];

    return Scaffold(
      body: SafeArea(child: screens[_currentIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF2DC867),
        unselectedItemColor: Colors.grey,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'HOME'),
          BottomNavigationBarItem(icon: Icon(Icons.grid_view), label: 'CONTROLS'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined), label: 'DATA'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), label: 'SETTINGS'),
        ],
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }

  Widget _buildHomeScreen(String waterLabel) {
    bool isWaterFull = _lastValidWaterStatus == "full";
    Color statusColor = _connectionStatus == "Connected" ? Colors.green : Colors.orange;
    String statusText = _connectionStatus == "Connected" 
        ? "System Online" 
        : "Connecting....";

    bool isPhWarningActive = (_lastValidPhValue < _minPhThreshold || _lastValidPhValue > _maxPhThreshold);
    int currentDayCount = _getElapsedPlantingDay(DateTime.now());

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Home', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 20),
          
          isPhWarningActive 
            ? Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.red[400], 
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(color: Colors.red.withAlpha(50), blurRadius: 10, offset: const Offset(0, 4))]
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        Text('SYSTEM CRITICAL WARNING', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                        Icon(Icons.warning_amber_rounded, color: Colors.white, size: 26),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('PH LEVEL', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(
                      'The system detected an unstable acid level of ${_lastValidPhValue.toStringAsFixed(2)} pH. Target range is ${_minPhThreshold.toStringAsFixed(1)} - ${_maxPhThreshold.toStringAsFixed(1)} pH.', 
                      style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)
                    ),
                  ],
                ),
              )
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF2DC867), 
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [BoxShadow(color: const Color(0xFF2DC867).withAlpha(50), blurRadius: 10, offset: const Offset(0, 4))]
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Current Status', style: TextStyle(color: Colors.white70, fontSize: 14)),
                        Icon(Icons.wb_sunny_outlined, color: Colors.white.withAlpha(230), size: 24),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text('Optimal Growth', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(color: Colors.white.withAlpha(45), borderRadius: BorderRadius.circular(30)),
                          child: Text('Day $currentDayCount', style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 24),

          const Text('Grow Bed 1 Metrics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _buildMetricGrid(waterLabel, isWaterFull),
          
          const SizedBox(height: 24),
          const Text('Grow Bed 2 Metrics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _buildMetricGrid(waterLabel, isWaterFull),
        ],
      ),
    );
  }

  Widget _buildMetricGrid(String waterLabel, bool isWaterFull) {
    bool isPhOptimal = _lastValidPhValue >= _minPhThreshold && _lastValidPhValue <= _maxPhThreshold;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildCleanCard(
                'ACIDITY (PH)', 
                _lastValidPhValue.toStringAsFixed(2), 
                isPhOptimal ? 'Normal' : 'Unstable', 
                isPhOptimal ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0), 
                isPhOptimal ? Colors.green : Colors.orange
              )
            ),
            const SizedBox(width: 16),
            Expanded(child: _buildCleanCard('TDS', '650 PPM', 'Optimal', const Color(0xFFE8F7ED), Colors.green)),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _buildCleanCard('WATER TEMP', _lastValidWaterTemp, 'Live', const Color(0xFFE8F7ED), Colors.green)),
            const SizedBox(width: 16),
            Expanded(
              child: _buildCleanCard(
                'BED WATER LEVEL',
                waterLabel,
                isWaterFull ? 'Optimal' : 'Warning',
                isWaterFull ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0),
                isWaterFull ? Colors.green : Colors.orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildCleanCard(
                'RESERVOIR WATER LEVEL', 
                '85%', 
                'Sensor Placeholder (Pending Hardware)', 
                const Color(0xFFE3F2FD), 
                Colors.blueAccent
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildControlScreen() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Hardware Controls', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const Spacer(),
          Center(
            child: Column(
              children: [
                ElevatedButton.icon(
                  onPressed: () => _toggleLed('toggleLED', 1),
                  icon: Icon(_led1On ? Icons.lightbulb : Icons.lightbulb_outline),
                  label: Text("LED 1 (GPIO 23): ${_led1On ? 'ON' : 'OFF'}"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _led1On ? const Color(0xFF2DC867) : Colors.redAccent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(280, 56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () => _toggleLed('toggleLED1', 2),
                  icon: Icon(_led2On ? Icons.lightbulb : Icons.lightbulb_outline),
                  label: Text("LED 2 (GPIO 22): ${_led2On ? 'ON' : 'OFF'}"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _led2On ? const Color(0xFF2DC867) : Colors.redAccent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(280, 56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildDataScreen() {
    List<HistoricalData> filteredLogs = _historyLogs.where((log) {
      if (_selectedFilterDate == null) return true;
      return log.timestamp.year == _selectedFilterDate!.year &&
          log.timestamp.month == _selectedFilterDate!.month &&
          log.timestamp.day == _selectedFilterDate!.day;
    }).toList();

    Map<String, List<HistoricalData>> categorizedLogs = {};

    for (var log in filteredLogs) {
      String category = _getDateCategoryHeader(log.timestamp);
      if (!categorizedLogs.containsKey(category)) {
        categorizedLogs[category] = [];
      }
      categorizedLogs[category]!.add(log);
    }

    List<String> sortedCategories = categorizedLogs.keys.toList()
      ..sort((a, b) {
        final aNum = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final bNum = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        return bNum.compareTo(aNum); 
      });

    List<dynamic> listElements = [];
    for (var cat in sortedCategories) {
      listElements.add(cat);
      listElements.addAll(categorizedLogs[cat]!);
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('System Log Data', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              IconButton(
                icon: Icon(
                  Icons.filter_alt_outlined, 
                  color: _selectedFilterDate != null ? const Color(0xFF2DC867) : Colors.grey
                ),
                onPressed: () async {
                  final selected = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now(),
                    firstDate: DateTime(2025),
                    lastDate: DateTime(2030),
                  );
                  if (selected != null) {
                    setState(() {
                      _selectedFilterDate = selected;
                    });
                  }
                },
              ),
            ],
          ),
          if (_selectedFilterDate != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Showing logs for: ${_selectedFilterDate!.year}-${_selectedFilterDate!.month.toString().padLeft(2, '0')}-${_selectedFilterDate!.day.toString().padLeft(2, '0')}",
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2DC867)),
                ),
                TextButton(
                  onPressed: () => setState(() => _selectedFilterDate = null),
                  child: const Text('Clear Filter', style: TextStyle(fontSize: 11, color: Colors.red)),
                )
              ],
            ),
          const SizedBox(height: 12),
          const Text(
            'Saved snapshots (taken every 20s for testing):', 
            style: TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic)
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filteredLogs.isEmpty
                ? const Center(
                    child: Text('No historical snapshots logged on this date.', style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    itemCount: listElements.length,
                    itemBuilder: (context, index) {
                      final item = listElements[index];

                      if (item is String) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 4.0),
                          child: Text(
                            item.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 14, 
                              fontWeight: FontWeight.bold, 
                              color: Color(0xFF2DC867),
                              letterSpacing: 1.2,
                            ),
                          ),
                        );
                      }

                      final log = item as HistoricalData;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          title: Text(
                            _formatDateTimeToReadable(log.timestamp),
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.black87),
                          ),
                          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => SnapshotDetailScreen(
                                  data: log, 
                                  formattedTime: _formatDateTimeToReadable(log.timestamp),
                                  minPh: _minPhThreshold,
                                  maxPh: _maxPhThreshold,
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          
          const Text('Network Configuration', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                TextField(
                  controller: _ipController,
                  decoration: const InputDecoration(
                    labelText: "ESP32 IP or Hostname",
                    hintText: "hydrodeck.local or 192.168.x.x",
                    border: OutlineInputBorder(),
                    suffixIcon: Icon(Icons.wifi),
                  ),
                  onChanged: (val) {
                    final trimmed = val.trim();
                    setState(() {
                      _esp32Ip = trimmed;
                    });
                    if (!kIsWeb) {
                      FlutterBackgroundService().invoke('updateIp', {'ip': trimmed});
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          const Text('Target Limit Parameters', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
          const SizedBox(height: 8),
          
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Minimum pH Limit', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(_minPhThreshold.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange)),
                  ],
                ),
                Slider(
                  value: _minPhThreshold,
                  min: 4.0,
                  max: 7.0,
                  divisions: 30,
                  activeColor: Colors.orange,
                  onChanged: (val) {
                    setState(() {
                      _minPhThreshold = val;
                    });
                    DatabaseHelper.instance.saveSettingsConfig(_minPhThreshold, _maxPhThreshold);
                    if (!kIsWeb) {
                      FlutterBackgroundService().invoke('updateLimits', {
                        'minPh': _minPhThreshold,
                        'maxPh': _maxPhThreshold,
                      });
                    }
                  },
                ),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Maximum pH Limit', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(_maxPhThreshold.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
                  ],
                ),
                Slider(
                  value: _maxPhThreshold,
                  min: 6.0,
                  max: 9.0,
                  divisions: 30,
                  activeColor: Colors.green,
                  onChanged: (val) {
                    setState(() {
                      _maxPhThreshold = val;
                    });
                    DatabaseHelper.instance.saveSettingsConfig(_minPhThreshold, _maxPhThreshold);
                    if (!kIsWeb) {
                      FlutterBackgroundService().invoke('updateLimits', {
                        'minPh': _minPhThreshold,
                        'maxPh': _maxPhThreshold,
                      });
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          ElevatedButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('End Planting Cycle?'),
                  content: const Text('This will archive your current dynamic run and log the final day count to your planting records.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context); 
                        widget.onEndPlanting(); 
                      },
                      child: const Text('End Cycle', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text(
              'End Planting',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        ],  
      ),
    );
  }

  Widget _buildCleanCard(String title, String value, String badgeText, Color bg, Color text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 6, offset: const Offset(0, 2))]
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
            child: Text(badgeText, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: text)),
          ),
        ],
      ),
    );
  }
}

class SnapshotDetailScreen extends StatelessWidget {
  final HistoricalData data;
  final String formattedTime;
  final double minPh;
  final double maxPh;

  const SnapshotDetailScreen({
    super.key, 
    required this.data, 
    required this.formattedTime,
    this.minPh = 5.5,
    this.maxPh = 6.8,
  });

  @override
  Widget build(BuildContext context) {
    bool isWaterFull = data.waterLevel == "Water full";
    bool isPhOptimal = data.pH >= minPh && data.pH <= maxPh;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Data Log Detail', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.black)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Overview - Captured State', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              'Logged: $formattedTime',
              style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 24), 

            const Text('Grow Bed 1 (Historical Metrics)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _buildStaticGrid(isWaterFull, isPhOptimal),
            
            const SizedBox(height: 24),
            const Text('Grow Bed 2 (Historical Metrics)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _buildStaticGrid(isWaterFull, isPhOptimal),
          ],
        ),
      ),
    );
  }

  Widget _buildStaticGrid(bool isWaterFull, bool isPhOptimal) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStaticCard(
                'ACIDITY (PH)', 
                '${data.pH.toStringAsFixed(2)} pH', 
                isPhOptimal ? 'Normal' : 'Unstable',
                bgOverride: isPhOptimal ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0),
                textOverride: isPhOptimal ? Colors.green : Colors.orange,
              )
            ),
            const SizedBox(width: 16),
            Expanded(child: _buildStaticCard('TDS', '650 PPM', 'Historical')),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _buildStaticCard('WATER TEMP', data.temperature, 'Log Data')),
            const SizedBox(width: 16),
            Expanded(
              child: _buildStaticCard(
                'GROW BED WATER LEVEL',
                data.waterLevel,
                isWaterFull ? 'Optimal' : 'Warning',
                bgOverride: isWaterFull ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0),
                textOverride: isWaterFull ? Colors.green : Colors.orange,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStaticCard(String title, String value, String badgeText, {Color? bgOverride, Color? textOverride}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white, 
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 6, offset: const Offset(0, 2))]
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: bgOverride ?? const Color(0xFFF0F0F0), 
              borderRadius: BorderRadius.circular(6)
            ),
            child: Text(
              badgeText, 
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: textOverride ?? Colors.grey)
            ),
          ),
        ],
      ),
    );
  }
}