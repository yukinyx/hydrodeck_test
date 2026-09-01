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
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'firebase_options.dart';

bool get _supportsBackgroundService =>
  !kIsWeb &&
  !const bool.fromEnvironment('FLUTTER_TEST') &&
  (defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS);

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
      version: 5,
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
        if (oldVersion < 4) {
          await db.execute('''
            ALTER TABLE historical_logs ADD COLUMN tds REAL NOT NULL DEFAULT 0.0
          ''');
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE historical_logs ADD COLUMN batchNumber INTEGER');
          await db.execute('ALTER TABLE active_session ADD COLUMN batchNumber INTEGER NOT NULL DEFAULT 1');
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
        waterLevel TEXT NOT NULL,
        tds REAL NOT NULL DEFAULT 0.0,
        batchNumber INTEGER
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
        startDate TEXT NOT NULL,
        batchNumber INTEGER NOT NULL
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
      'tds': log.tds,
      'batchNumber': log.batchNumber,
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
      tds: (json['tds'] as num?)?.toDouble() ?? 0.0,
      batchNumber: json['batchNumber'] as int?,
    )).toList();
  }

  Future<List<HistoricalData>> getLogsForBatch(int batchNumber) async {
    final db = await instance.database;
    if (db == null) return [];
    final result = await db.query('historical_logs', where: 'batchNumber = ?', whereArgs: [batchNumber], orderBy: 'timestamp DESC');
    return result.map((json) => HistoricalData(
      timestamp: DateTime.parse(json['timestamp'] as String),
      pH: (json['pH'] as num).toDouble(),
      temperature: json['temperature'] as String,
      waterLevel: json['waterLevel'] as String,
      tds: (json['tds'] as num?)?.toDouble() ?? 0.0,
      batchNumber: json['batchNumber'] as int?,
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
  Future<void> saveActiveSession(DateTime startDate, int batchNumber) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert(
      'active_session',
      {'id': 1, 'startDate': startDate.toIso8601String(), 'batchNumber': batchNumber},
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

  Future<int?> getActiveBatchNumber() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query('active_session', where: 'id = ?', whereArgs: [1]);
    return result.isEmpty ? null : result.first['batchNumber'] as int?;
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
    if (db == null) return {'minPh': 5.5, 'maxPh': 7.0};
    final result = await db.query('settings_config', where: 'id = ?', whereArgs: [1]);
    if (result.isNotEmpty) {
      return {
        'minPh': (result.first['minPh'] as num).toDouble(),
        'maxPh': (result.first['maxPh'] as num).toDouble(),
      };
    }
    return {'minPh': 5.5, 'maxPh': 7.0};
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

    await _notificationsPlugin.initialize(settings: settings);

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
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: '⚠️ Critical pH Alert',
      body: 'pH level has remained in critical range (${ph.toStringAsFixed(2)}) for over 20 seconds!',
      notificationDetails: details,
    );
  }
}

class GrowBedReading {
  final double temperature;
  final double ph;
  final double tds;
  final bool waterFull;

  const GrowBedReading({
    required this.temperature,
    required this.ph,
    required this.tds,
    required this.waterFull,
  });

  factory GrowBedReading.empty() => const GrowBedReading(
        temperature: 25.0,
        ph: 7.0,
        tds: 0.0,
        waterFull: false,
      );

  factory GrowBedReading.fromMap(Map<String, dynamic> map) {
    final temperature = (map['temp'] is num)
        ? (map['temp'] as num).toDouble()
        : double.tryParse((map['temp'] ?? '25.0').toString()) ?? 25.0;
    final ph = (map['ph'] is num)
        ? (map['ph'] as num).toDouble()
        : double.tryParse((map['ph'] ?? '7.0').toString()) ?? 7.0;
    final tds = (map['tds'] is num)
        ? (map['tds'] as num).toDouble()
        : double.tryParse((map['tds'] ?? '0').toString()) ?? 0.0;
    final waterValue = map['water'];
    final waterFull = switch (waterValue) {
      bool b => b,
      int i => i != 0,
      String s => s.toLowerCase() == 'full' || s == '1' || s == 'on',
      _ => false,
    };

    return GrowBedReading(
      temperature: temperature,
      ph: ph,
      tds: tds,
      waterFull: waterFull,
    );
  }

  Map<String, dynamic> toMap() => {
        'temp': temperature,
        'ph': ph,
        'tds': tds,
        'water': waterFull ? 'full' : 'low',
      };
}

class HydrodeckTelemetry {
  final GrowBedReading bed1;
  final GrowBedReading bed2;
  final bool growLightOn;

  const HydrodeckTelemetry({
    required this.bed1,
    required this.bed2,
    required this.growLightOn,
  });

  static double _readDouble(Map<String, dynamic> json, String key, {double fallback = 0.0}) {
    final value = json[key];
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? fallback;
    return fallback;
  }

  static bool _readWaterFlag(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.toLowerCase() == 'full' || value == '1' || value.toLowerCase() == 'on';
    return false;
  }

  static bool _readBoolLike(Map<String, dynamic> map, List<String> keys, {bool fallback = false}) {
    for (final key in keys) {
      final value = map[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.toLowerCase();
        if (normalized == 'true' || normalized == 'on' || normalized == '1') return true;
        if (normalized == 'false' || normalized == 'off' || normalized == '0') return false;
      }
    }
    return fallback;
  }

  factory HydrodeckTelemetry.fromJson(Map<String, dynamic> json) {
    final wireMap = Map<String, dynamic>.from(json);

    final bed1Map = {
      'temp': wireMap['temp1'] ?? wireMap['bed1']?['temp'] ?? wireMap['set1']?['temp'] ?? 25.0,
      'ph': wireMap['ph1'] ?? wireMap['bed1']?['ph'] ?? wireMap['set1']?['ph'] ?? 7.0,
      'tds': wireMap['tds1'] ?? wireMap['bed1']?['tds'] ?? wireMap['set1']?['tds'] ?? 0.0,
      'water': wireMap['water1'] ?? wireMap['bed1']?['water'] ?? wireMap['set1']?['water'] ?? 'low',
    };

    final bed2Map = {
      'temp': wireMap['temp2'] ?? wireMap['bed2']?['temp'] ?? wireMap['set2']?['temp'] ?? 25.0,
      'ph': wireMap['ph2'] ?? wireMap['bed2']?['ph'] ?? wireMap['set2']?['ph'] ?? 7.0,
      'tds': wireMap['tds2'] ?? wireMap['bed2']?['tds'] ?? wireMap['set2']?['tds'] ?? 0.0,
      'water': wireMap['water2'] ?? wireMap['bed2']?['water'] ?? wireMap['set2']?['water'] ?? 'low',
    };

    final bed1 = GrowBedReading(
      temperature: _readDouble(bed1Map, 'temp', fallback: 25.0),
      ph: _readDouble(bed1Map, 'ph', fallback: 7.0),
      tds: _readDouble(bed1Map, 'tds', fallback: 0.0),
      waterFull: _readWaterFlag(bed1Map, 'water'),
    );

    final bed2 = GrowBedReading(
      temperature: _readDouble(bed2Map, 'temp', fallback: 25.0),
      ph: _readDouble(bed2Map, 'ph', fallback: 7.0),
      tds: _readDouble(bed2Map, 'tds', fallback: 0.0),
      waterFull: _readWaterFlag(bed2Map, 'water'),
    );

    final actuatorMap = Map<String, dynamic>.from(wireMap['actuators'] is Map ? wireMap['actuators'] : {});
    final allMap = <String, dynamic>{
      ...Map<String, dynamic>.from(wireMap),
      ...Map<String, dynamic>.from(actuatorMap),
    };

    final growLightOn = _readBoolLike(
      allMap,
      const [
        'growLight', 'grow_light', 'growLightBoth', 'growLight1', 'growLight2',
        'growLight1_2', 'growLightAll', 'grow_light_all',
      ],
      fallback: false,
    );

    final waterPump1State = _readBoolLike(allMap, const ['waterPump1']);
    final waterPump2State = _readBoolLike(allMap, const ['waterPump2']);
    final phUp1State = _readBoolLike(allMap, const ['phUp1']);
    final phDown1State = _readBoolLike(allMap, const ['phDown1']);
    final nutrient1State = _readBoolLike(allMap, const ['nutrient1']);
    final phUp2State = _readBoolLike(allMap, const ['phUp2']);
    final phDown2State = _readBoolLike(allMap, const ['phDown2']);
    final nutrient2State = _readBoolLike(allMap, const ['nutrient2']);

    if (waterPump1State || waterPump2State || phUp1State || phDown1State || nutrient1State || phUp2State || phDown2State || nutrient2State) {
      // no-op: these values are parsed for future UI use; the main display runs from the bed sensor payload.
    }

    return HydrodeckTelemetry(
      bed1: bed1,
      bed2: bed2,
      growLightOn: growLightOn,
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

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }
  } catch (_) {}

  String targetIp = "hydrodeck.local";
  double lastPh = 7.0;
  String lastTemp = "25.0°C";
  String lastWater = "low";
  double lastTds = 0.0;
  bool isConnected = false;

  bool isAppClosed = false; 
  bool isPlantingActive = false;
  int? activeBatchNumber;

  double minPhThreshold = 5.5;
  double maxPhThreshold = 7.0;

  DateTime? criticalPhStart;
  DateTime? lastAlertTime;

  bool isPolling = false; // Prevents timer stack overlap

  try {
    targetIp = await DatabaseHelper.instance.getActiveIp();
    final limits = await DatabaseHelper.instance.getSettingsConfig();
    minPhThreshold = limits['minPh']!;
    maxPhThreshold = limits['maxPh']!;
    
    final activeSession = await DatabaseHelper.instance.getActiveSession();
    activeBatchNumber = await DatabaseHelper.instance.getActiveBatchNumber();
    isPlantingActive = activeSession != null;

    final logs = await DatabaseHelper.instance.getLogs();
    if (logs.isNotEmpty) {
      lastPh = logs.first.pH;
      lastTemp = logs.first.temperature;
      lastWater = logs.first.waterLevel == "Water full" ? "full" : "low";
      lastTds = logs.first.tds;
    }
  } catch (_) {}

  service.on('setPlantingState').listen((event) {
    if (event != null && event['active'] != null) {
      isPlantingActive = event['active'] as bool;
      if (isPlantingActive) {
        DatabaseHelper.instance.getActiveBatchNumber().then((batchNumber) {
          activeBatchNumber = batchNumber;
        });
      }
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

  String sanitizeHost(String input) {
    String host = input.trim();
    host = host.replaceAll(RegExp(r'^https?://'), '');
    host = host.replaceAll(RegExp(r'/.*$'), '');
    return host.isEmpty ? "hydrodeck.local" : host;
  }

  Future<Map<String, dynamic>?> fetchStatus(String host, Duration timeout) async {
    try {
      final res = await http.get(
        Uri.parse('http://$host/status'),
        headers: {'Connection': 'close'},
      ).timeout(timeout);

      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          return {'host': host, 'data': decoded};
        }
        if (decoded is Map) {
          return {'host': host, 'data': Map<String, dynamic>.from(decoded)};
        }
      }
    } catch (_) {}
    return null;
  }

  Map<String, dynamic> normalizeStatusPayload(Map<String, dynamic> data) {
    final bed1 = {
      'temp': data['temp1'] ?? data['bed1']?['temp'] ?? 25.0,
      'ph': data['ph1'] ?? data['bed1']?['ph'] ?? 7.0,
      'tds': data['tds1'] ?? data['bed1']?['tds'] ?? 0.0,
      'water': data['water1'] ?? data['bed1']?['water'] ?? 'low',
    };
    final bed2 = {
      'temp': data['temp2'] ?? data['bed2']?['temp'] ?? 25.0,
      'ph': data['ph2'] ?? data['bed2']?['ph'] ?? 7.0,
      'tds': data['tds2'] ?? data['bed2']?['tds'] ?? 0.0,
      'water': data['water2'] ?? data['bed2']?['water'] ?? 'low',
    };

    final bed2Ph = bed2['ph'] is num ? (bed2['ph'] as num).toDouble() : 7.0;
    final bed2Temp = bed2['temp'] is num ? (bed2['temp'] as num).toDouble() : 25.0;
    final bed2Tds = bed2['tds'] is num ? (bed2['tds'] as num).toDouble() : 0.0;
    final bed2Water = bed2['water'] is String ? bed2['water'] as String : 'low';
    final growLightFlag = data['grow_light'] ?? data['growLight'] ?? false;

    return {
      'bed1': bed1,
      'bed2': bed2,
      'growLight': growLightFlag,
      'ph': bed2Ph,
      'temp': '${bed2Temp.toStringAsFixed(1)}°C',
      'water': bed2Water,
      'tds': bed2Tds,
    };
  }

  Timer.periodic(const Duration(seconds: 3), (timer) async {
    if (isPolling) return; // Skip if previous poll hasn't resolved
    isPolling = true;

    bool found = false;
    String cleanTargetIp = sanitizeHost(targetIp);

    // 1. Fast attempt to primary target IP
    final primaryResult = await fetchStatus(cleanTargetIp, const Duration(milliseconds: 1200));

    if (primaryResult != null) {
      final normalized = normalizeStatusPayload(Map<String, dynamic>.from(primaryResult['data'] as Map));
      final bed1 = normalized['bed1'] as Map<String, dynamic>;
      final bed2 = normalized['bed2'] as Map<String, dynamic>;

      if (bed2['ph'] != null) {
        lastPh = (bed2['ph'] is num) ? (bed2['ph'] as num).toDouble() : lastPh;
      }
      if (bed2['temp'] != null && bed2['temp'] != 0.0) {
        lastTemp = "${(bed2['temp'] is num ? (bed2['temp'] as num).toDouble() : double.tryParse(bed2['temp'].toString()) ?? 25.0).toStringAsFixed(1)}°C";
      }
      if (bed2['tds'] != null) {
        lastTds = (bed2['tds'] is num) ? (bed2['tds'] as num).toDouble() : lastTds;
      }
      lastWater = (bed2['water'] ?? lastWater).toString();

      service.invoke('telemetryUpdate', {
        'isConnected': true,
        'ip': cleanTargetIp,
        'ph': lastPh,
        'temp': lastTemp,
        'water': lastWater,
        'tds': lastTds,
        'bed1': bed1,
        'bed2': bed2,
        'growLight': normalized['growLight'] ?? false,
      });

      targetIp = cleanTargetIp;
      isConnected = true;
      found = true;
    }

    // 2. Concurrently probe fallback local hosts if primary target failed
    if (!found) {
      final List<String> fallbackHosts = [
        "hydrodeck.local",
        "192.168.1.100",
        "192.168.0.100",
        "10.0.2.2"
      ].map(sanitizeHost).where((h) => h != cleanTargetIp).toSet().toList();

      final results = await Future.wait(
        fallbackHosts.map((h) => fetchStatus(h, const Duration(milliseconds: 1200))),
      );

      for (final res in results) {
        if (res != null) {
          final host = res['host'] as String;
          final normalized = normalizeStatusPayload(Map<String, dynamic>.from(res['data'] as Map));
          final bed1 = normalized['bed1'] as Map<String, dynamic>;
          final bed2 = normalized['bed2'] as Map<String, dynamic>;

          if (bed2['ph'] != null) {
            lastPh = (bed2['ph'] is num) ? (bed2['ph'] as num).toDouble() : lastPh;
          }
          if (bed2['temp'] != null && bed2['temp'] != 0.0) {
            lastTemp = "${(bed2['temp'] is num ? (bed2['temp'] as num).toDouble() : double.tryParse(bed2['temp'].toString()) ?? 25.0).toStringAsFixed(1)}°C";
          }
          if (bed2['tds'] != null) {
            lastTds = (bed2['tds'] is num) ? (bed2['tds'] as num).toDouble() : lastTds;
          }
          lastWater = (bed2['water'] ?? lastWater).toString();

          service.invoke('telemetryUpdate', {
            'isConnected': true,
            'ip': host,
            'ph': lastPh,
            'temp': lastTemp,
            'water': lastWater,
            'tds': lastTds,
            'bed1': bed1,
            'bed2': bed2,
            'growLight': normalized['growLight'] ?? false,
          });

          targetIp = host;
          DatabaseHelper.instance.saveActiveIp(targetIp);
          isConnected = true;
          found = true;
          break;
        }
      }
    }

    // 3. Fallback to Firebase Realtime Database for Remote Network Connection
    if (!found) {
      try {
        final dbRef = FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: "https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/",
        ).ref('hydrodeck');

        final snapshot = await dbRef.get().timeout(const Duration(milliseconds: 2500));
        if (snapshot.exists && snapshot.value != null) {
          final data = Map<String, dynamic>.from(snapshot.value as Map);
          if (data['ph'] != null) {
            lastPh = (data['ph'] is num) ? (data['ph'] as num).toDouble() : lastPh;
          }
          if (data['temp'] != null) {
            lastTemp = "${data['temp']}°C";
          }
          if (data['tds'] != null) {
            lastTds = (data['tds'] is num) ? (data['tds'] as num).toDouble() : lastTds;
          }
          if (data['water'] != null) {
            lastWater = data['water'].toString();
          }
          isConnected = true;
          found = true;
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
      'tds': lastTds,
      'bed1': {
        'temp': 25.0,
        'ph': lastPh,
        'tds': lastTds,
        'water': lastWater,
      },
      'bed2': {
        'temp': double.tryParse(lastTemp.replaceAll('°C', '')) ?? 25.0,
        'ph': lastPh,
        'tds': lastTds,
        'water': lastWater,
      },
      'growLight': false,
    });

    isPolling = false;
  });

  Timer.periodic(const Duration(seconds: 20), (timer) async {
    if (!isPlantingActive) return;

    final snapshot = HistoricalData(
      timestamp: DateTime.now(),
      pH: lastPh,
      temperature: lastTemp,
      waterLevel: lastWater == "full" ? "Water full" : "Needs water",
      tds: lastTds,
      batchNumber: activeBatchNumber,
    );

    try {
      await DatabaseHelper.instance.insertLog(snapshot);
      service.invoke('newSnapshotLogged', {
        'timestamp': snapshot.timestamp.toIso8601String(),
        'pH': snapshot.pH,
        'temperature': snapshot.temperature,
        'waterLevel': snapshot.waterLevel,
        'tds': snapshot.tds,
      });
    } catch (_) {}
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (_) {}

  if (_supportsBackgroundService) {
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
    if (_supportsBackgroundService) {
      try {
        FlutterBackgroundService().invoke('appState', {'state': 'foreground'});
      } catch (_) {}
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
  final double tds;
  final int? batchNumber;

  HistoricalData({
    required this.timestamp,
    required this.pH,
    required this.temperature,
    required this.waterLevel,
    required this.tds,
    this.batchNumber,
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
          biometricOnly: true,
          persistAcrossBackgrounding: true,
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
                        'Change PIN specifically for opening the app on this device. The factory PIN remains usable for setup resets.',
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
                        activeThumbColor: const Color(0xFF2DC867),
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
        biometricOnly: true,
        persistAcrossBackgrounding: true,
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
    if (!_supportsBackgroundService) return;
    try {
      _bgSubscription = FlutterBackgroundService().on('telemetryUpdate').listen((event) {
        if (event != null && event['ip'] != null && mounted) {
          setState(() {
            _activeEsp32Ip = event['ip'];
          });
        }
      });
    } catch (_) {}
  }

  void _startPlanting() async {
    final now = DateTime.now();
    final batchNumber = _pastPlantingRuns.length + 1;
    await DatabaseHelper.instance.saveActiveSession(now, batchNumber);

    if (_supportsBackgroundService) {
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
    int totalDays = (now.difference(_plantingStartDate!).inDays + 1).clamp(1, 999999);

    final newRecord = PlantingRecord(
      batchNumber: _pastPlantingRuns.length + 1,
      startDate: _plantingStartDate!,
      endDate: now,
      totalDays: totalDays,
    );

    await DatabaseHelper.instance.insertPlantingRecord(newRecord);
    await DatabaseHelper.instance.clearActiveSession();

    if (_supportsBackgroundService) {
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
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => BatchHistoryScreen(record: run),
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
  static final Guid _bleServiceUuid = Guid('7b7b0001-7b7b-4a4b-8b7b-000000000001');
  static final Guid _bleWifiCharacteristicUuid = Guid('7b7b0002-7b7b-4a4b-8b7b-000000000002');
  static final Guid _bleStatusCharacteristicUuid = Guid('7b7b0003-7b7b-4a4b-8b7b-000000000003');
  static const String _bleDeviceName = 'ESP32-HYDRODECK';

  int _currentIndex = 0;

  late String _esp32Ip;
  late TextEditingController _ipController;
  
  String _connectionStatus = "Fetching...";

  GrowBedReading _bed1 = GrowBedReading.empty();
  GrowBedReading _bed2 = GrowBedReading.empty();
  bool _growLightOn = false;
  bool _isGrowLightToggling = false;
  final Map<String, bool> _controlStates = {
    'bed1_water': false,
    'bed1_ph_up': false,
    'bed1_ph_down': false,
    'bed1_nutrient': false,
    'bed2_water': false,
    'bed2_ph_up': false,
    'bed2_ph_down': false,
    'bed2_nutrient': false,
  };

  String _lastValidWaterStatus = "low";

  StreamSubscription? _telemetrySub;
  StreamSubscription? _snapshotSub;
  StreamSubscription? _firebaseSub;

  List<HistoricalData> _historyLogs = [];
  DateTime? _selectedFilterDate;

  late TextEditingController _wifiSsidController;
  late TextEditingController _wifiPasswordController;
  bool _isBleConnecting = false;
  String _bleStatus = 'Bluetooth not connected';

  double _minPhThreshold = 5.5;
  double _maxPhThreshold = 7.0;

  @override
  void initState() {
    super.initState();
    _esp32Ip = widget.initialIp;
    _ipController = TextEditingController(text: _esp32Ip);
    _wifiSsidController = TextEditingController();
    _wifiPasswordController = TextEditingController();
    _loadStoredLogsAndSettings();
    _subscribeToFirebase();
    _subscribeToBackgroundUpdates();
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _snapshotSub?.cancel();
    _firebaseSub?.cancel();
    _ipController.dispose();
    _wifiSsidController.dispose();
    _wifiPasswordController.dispose();
    super.dispose();
  }

  void _subscribeToFirebase() {
    if (kIsWeb) return;

    try {
      final ref = FirebaseDatabase.instance.ref('hydrodeck');
      _firebaseSub = ref.onValue.listen((event) {
        final value = event.snapshot.value;
        if (value is! Map) return;

        final payload = Map<String, dynamic>.from(value);
        final telemetry = HydrodeckTelemetry.fromJson(payload);

        if (!mounted) return;
        setState(() {
          _bed1 = telemetry.bed1;
          _bed2 = telemetry.bed2;
          _growLightOn = telemetry.growLightOn;
          _connectionStatus = 'Connected';
          if (payload['ip'] != null) {
            _esp32Ip = payload['ip'].toString();
            _ipController.text = _esp32Ip;
          }
        });
      });
    } catch (_) {
      // Firebase is unavailable; telemetry will fall back to manual polling.
    }
  }

  Future<void> _loadStoredLogsAndSettings() async {
    final activeBatchNumber = await DatabaseHelper.instance.getActiveBatchNumber();
    final storedLogs = activeBatchNumber == null
      ? <HistoricalData>[]
      : await DatabaseHelper.instance.getLogsForBatch(activeBatchNumber);
    final config = await DatabaseHelper.instance.getSettingsConfig();
    if (mounted) {
      setState(() {
        _historyLogs = storedLogs;
        _minPhThreshold = config['minPh'] ?? 5.5;
        _maxPhThreshold = config['maxPh'] ?? 7.0;
        
        if (storedLogs.isNotEmpty) {
          _lastValidWaterStatus = storedLogs.first.waterLevel == "Water full" ? "full" : "low";
          _bed2 = GrowBedReading(
            temperature: double.tryParse(storedLogs.first.temperature.replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 25.0,
            ph: storedLogs.first.pH,
            tds: storedLogs.first.tds,
            waterFull: _lastValidWaterStatus == 'full',
          );
        }
      });
    }
  }

  void _subscribeToBackgroundUpdates() {
    if (kIsWeb || !_supportsBackgroundService) return;

    try {
      _telemetrySub = FlutterBackgroundService().on('telemetryUpdate').listen((event) {
        if (event != null && mounted) {
          setState(() {
            _connectionStatus = (event['isConnected'] == true) ? "Connected" : "Disconnected";
            if (event['bed1'] != null) {
              _bed1 = GrowBedReading.fromMap(Map<String, dynamic>.from(event['bed1'] as Map));
            }
            if (event['bed2'] != null) {
              _bed2 = GrowBedReading.fromMap(Map<String, dynamic>.from(event['bed2'] as Map));
            }
            if (event['growLight'] != null) {
              _growLightOn = event['growLight'] is bool
                  ? event['growLight'] as bool
                  : (event['growLight'].toString() == '1' || event['growLight'].toString().toLowerCase() == 'true');
            }
            if (event['water'] != null) {
              _lastValidWaterStatus = event['water'];
            }
            if (event['ip'] != null) {
              _esp32Ip = event['ip'];
            }
            _lastValidWaterStatus = _bed2.waterFull ? 'full' : 'low';
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
            tds: (event['tds'] as num?)?.toDouble() ?? 0.0,
          );
          setState(() {
            _historyLogs.insert(0, newLog);
          });
        }
      });
    } catch (_) {
      // The background service is not supported in widget tests and desktop runners.
      _telemetrySub = null;
      _snapshotSub = null;
    }
  }

  int _getElapsedPlantingDay(DateTime timestamp) {
    final startDay = DateTime(widget.startDate.year, widget.startDate.month, widget.startDate.day);
    final currentDay = DateTime(timestamp.year, timestamp.month, timestamp.day);
    return (currentDay.difference(startDay).inDays + 1).clamp(1, 999999);
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

  Future<void> _toggleGrowLight() async {
    final target = _esp32Ip.trim().isEmpty ? 'hydrodeck.local' : _esp32Ip.trim();
    final nextState = !_growLightOn ? 1 : 0;
    final uri = Uri.parse('http://$target/control?light=1&state=$nextState');

    setState(() {
      _growLightOn = !_growLightOn;
      _isGrowLightToggling = true;
    });

    try {
      final response = await http.get(uri, headers: {'Connection': 'close'}).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ESP32 acknowledged the command, but the response was unexpected.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Grow light control could not reach the ESP32.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isGrowLightToggling = false);
    }
  }

  Future<void> _toggleActuator(String key, int pumpNumber, {bool allowHardware = true}) async {
    if (!allowHardware) {
      setState(() {
        _controlStates[key] = !(_controlStates[key] ?? false);
      });
      return;
    }

    final target = _esp32Ip.trim().isEmpty ? 'hydrodeck.local' : _esp32Ip.trim();
    final nextValue = !(_controlStates[key] ?? false) ? 1 : 0;
    final uri = Uri.parse('http://$target/control?pump=$pumpNumber&state=$nextValue');

    setState(() {
      _controlStates[key] = !(_controlStates[key] ?? false);
    });

    try {
      final response = await http.get(uri, headers: {'Connection': 'close'}).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Actuator command was not acknowledged by the ESP32.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pump control could not reach the ESP32.')),
        );
      }
    }
  }

  Future<void> _connectAndProvisionWifi() async {
    final ssid = _wifiSsidController.text.trim();
    final password = _wifiPasswordController.text;
    if (ssid.isEmpty || password.isEmpty) {
      setState(() => _bleStatus = 'Enter both Wi-Fi fields first');
      return;
    }

    setState(() {
      _isBleConnecting = true;
      _bleStatus = 'Searching for $_bleDeviceName...';
    });

    BluetoothDevice? device;
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final permissions = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
        ].request();
        final missingRequiredPermissions = permissions.values.any(
          (status) => status != PermissionStatus.granted && status != PermissionStatus.limited,
        );
        if (missingRequiredPermissions) {
          throw Exception('Bluetooth and location permissions are required');
        }
      }
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
        await FlutterBluePlus.adapterState.firstWhere((state) => state == BluetoothAdapterState.on);
      }

      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(
        withServices: [_bleServiceUuid],
        timeout: const Duration(seconds: 10),
        androidUsesFineLocation: true,
      );
      final results = await FlutterBluePlus.scanResults.firstWhere((scanResults) {
        return scanResults.any((result) {
          final names = [result.device.platformName, result.advertisementData.advName];
          final matchesName = names.any((name) =>
              name == _bleDeviceName || name.toLowerCase().contains('esp32'));
          final matchesService = result.advertisementData.serviceUuids.any(
            (uuid) => uuid == _bleServiceUuid,
          );
          return matchesName || matchesService;
        });
      }).timeout(const Duration(seconds: 15));
      for (final result in results) {
        final names = [result.device.platformName, result.advertisementData.advName];
        final matchesName = names.any((name) =>
            name == _bleDeviceName || name.toLowerCase().contains('esp32'));
        final matchesService = result.advertisementData.serviceUuids.any(
          (uuid) => uuid == _bleServiceUuid,
        );
        if (matchesName || matchesService) {
          device = result.device;
          break;
        }
      }
      await FlutterBluePlus.stopScan();
      if (device == null) throw Exception('ESP32-HYDRODECK was not found');

      await device.connect(timeout: const Duration(seconds: 15), license: License.nonprofit);
      final services = await device.discoverServices();
      BluetoothCharacteristic? wifiCharacteristic;
      BluetoothCharacteristic? statusCharacteristic;
      for (final service in services) {
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == _bleWifiCharacteristicUuid) {
            wifiCharacteristic = characteristic;
          }
          if (characteristic.uuid == _bleStatusCharacteristicUuid) {
            statusCharacteristic = characteristic;
          }
        }
      }
      if (wifiCharacteristic == null || statusCharacteristic == null) {
        throw Exception('Wi-Fi setup characteristics not found');
      }

      await statusCharacteristic.setNotifyValue(true);
      final acknowledgement = statusCharacteristic.onValueReceived
          .map((value) => utf8.decode(value, allowMalformed: true))
          .firstWhere((value) => value == 'WIFI_CONNECTED' || value == 'WIFI_FAILED')
          .timeout(const Duration(seconds: 35));
      final payload = utf8.encode('$ssid\n$password');
      try {
        await wifiCharacteristic.write(payload, allowLongWrite: true);
      } catch (error) {
        if (!error.toString().contains('133')) rethrow;
      }
      final result = await acknowledgement;
      if (result == 'WIFI_FAILED') {
        throw Exception('ESP32 could not connect to the supplied Wi-Fi');
      }
      setState(() => _bleStatus = '$_bleDeviceName connected to Wi-Fi');
    } catch (error) {
      final message = error is TimeoutException
          ? 'ESP32-HYDRODECK was not found. Keep it powered and try again.'
          : 'Bluetooth setup failed: $error';
      setState(() => _bleStatus = message);
    } finally {
      await FlutterBluePlus.stopScan();
      if (device != null && device.isConnected) {
        await device.disconnect();
      }
      if (mounted) setState(() => _isBleConnecting = false);
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
    final statusColor = _connectionStatus == "Connected" ? Colors.green : Colors.orange;
    final statusText = _connectionStatus == "Connected" ? "System Online" : "Connecting....";
    final isBed2Warning = _bed2.ph < _minPhThreshold || _bed2.ph > _maxPhThreshold;
    final currentDayCount = _getElapsedPlantingDay(DateTime.now());

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

          isBed2Warning
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.red[400],
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [BoxShadow(color: Colors.red.withAlpha(50), blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: const [
                          Text('GROW BED 2 pH WARNING', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                          Icon(Icons.warning_amber_rounded, color: Colors.white, size: 26),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text('pH ALERT', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(
                        'Grow bed 2 is outside the target range at ${_bed2.ph.toStringAsFixed(2)} pH. Target range is ${_minPhThreshold.toStringAsFixed(1)} - ${_maxPhThreshold.toStringAsFixed(1)} pH.',
                        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
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
                    boxShadow: [BoxShadow(color: const Color(0xFF2DC867).withAlpha(50), blurRadius: 10, offset: const Offset(0, 4))],
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
          _buildGrowBedMetrics('Grow Bed 1', _bed1),
          const SizedBox(height: 24),
          const Text('Grow Bed 2 Metrics', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _buildGrowBedMetrics('Grow Bed 2', _bed2),
        ],
      ),
    );
  }

  Widget _buildGrowBedMetrics(String title, GrowBedReading data) {
    final isPhOptimal = data.ph >= _minPhThreshold && data.ph <= _maxPhThreshold;
    final isTdsOptimal = data.tds >= 400 && data.tds <= 900;
    final waterLabel = data.waterFull ? 'Water full' : 'Needs water';

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildCleanCard(
                'ACIDITY (PH)',
                data.ph.toStringAsFixed(2),
                isPhOptimal ? 'Normal' : 'Unstable',
                isPhOptimal ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0),
                isPhOptimal ? Colors.green : Colors.orange,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildCleanCard(
                'TDS',
                '${data.tds.toStringAsFixed(0)} PPM',
                isTdsOptimal ? 'Optimal' : 'Warning',
                isTdsOptimal ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0),
                isTdsOptimal ? Colors.green : Colors.orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildCleanCard(
                'WATER TEMP',
                '${data.temperature.toStringAsFixed(1)}°C',
                'Live',
                const Color(0xFFE8F7ED),
                Colors.green,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildCleanCard(
                'BED WATER LEVEL',
                waterLabel,
                data.waterFull ? 'Optimal' : 'Warning',
                data.waterFull ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0),
                data.waterFull ? Colors.green : Colors.orange,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildControlToggle(String label, String key, {int pumpNumber = 0, bool allowHardware = true}) {
    final isOn = _controlStates[key] ?? false;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87),
            ),
          ),
          SizedBox(
            width: 82,
            child: ElevatedButton(
              onPressed: () => _toggleActuator(key, pumpNumber, allowHardware: allowHardware),
              style: ElevatedButton.styleFrom(
                backgroundColor: isOn ? const Color(0xFF2DC867) : Colors.grey.shade500,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(isOn ? 'ON' : 'OFF'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Hardware Controls', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2DC867).withValues(alpha: 20),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Grow Bed 1', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 12),
                          _buildControlToggle('Water Pump', 'bed1_water', pumpNumber: 1),
                          const SizedBox(height: 10),
                          _buildControlToggle('pH Up', 'bed1_ph_up', pumpNumber: 3, allowHardware: false),
                          const SizedBox(height: 10),
                          _buildControlToggle('pH Down', 'bed1_ph_down', pumpNumber: 4, allowHardware: false),
                          const SizedBox(height: 10),
                          _buildControlToggle('Nutrient', 'bed1_nutrient', pumpNumber: 5, allowHardware: false),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2DC867).withValues(alpha: 20),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Grow Bed 2', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 12),
                          _buildControlToggle('Water Pump', 'bed2_water', pumpNumber: 2),
                          const SizedBox(height: 10),
                          _buildControlToggle('pH Up', 'bed2_ph_up', pumpNumber: 6, allowHardware: false),
                          const SizedBox(height: 10),
                          _buildControlToggle('pH Down', 'bed2_ph_down', pumpNumber: 6, allowHardware: false),
                          const SizedBox(height: 10),
                          _buildControlToggle('Nutrient', 'bed2_nutrient', pumpNumber: 5, allowHardware: false),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Row(
              children: [
                const Icon(Icons.lightbulb_outline, size: 24, color: Color(0xFF2DC867)),
                const SizedBox(width: 12),
                const Expanded(child: Text('Grow Lights', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                const SizedBox(width: 12),
                SizedBox(
                  width: 110,
                  child: ElevatedButton(
                    key: const ValueKey('grow-light-button'),
                    onPressed: _isGrowLightToggling ? null : _toggleGrowLight,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _growLightOn ? const Color(0xFF2DC867) : Colors.grey.shade500,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(_isGrowLightToggling ? '...' : (_growLightOn ? 'ON' : 'OFF')),
                  ),
                ),
              ],
            ),
          ),
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
                    if (_supportsBackgroundService) {
                      FlutterBackgroundService().invoke('updateIp', {'ip': trimmed});
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          const Text('Bluetooth Wi-Fi Setup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                TextField(
                  controller: _wifiSsidController,
                  decoration: const InputDecoration(labelText: 'Wi-Fi SSID', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _wifiPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Wi-Fi Password', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isBleConnecting ? null : _connectAndProvisionWifi,
                    icon: const Icon(Icons.bluetooth),
                    label: Text(_isBleConnecting ? 'Connecting...' : 'Connect using Bluetooth'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2DC867),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_bleStatus, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
                    if (_supportsBackgroundService) {
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
                    if (_supportsBackgroundService) {
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

class BatchHistoryScreen extends StatefulWidget {
  final PlantingRecord record;

  const BatchHistoryScreen({super.key, required this.record});

  @override
  State<BatchHistoryScreen> createState() => _BatchHistoryScreenState();
}

class _BatchHistoryScreenState extends State<BatchHistoryScreen> {
  late Future<List<HistoricalData>> _logsFuture;

  @override
  void initState() {
    super.initState();
    _logsFuture = DatabaseHelper.instance.getLogsForBatch(widget.record.batchNumber);
  }

  String _formatDateTime(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final period = value.hour >= 12 ? 'PM' : 'AM';
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} $hour:${value.minute.toString().padLeft(2, '0')} $period';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Batch #${widget.record.batchNumber} System Logs')),
      body: FutureBuilder<List<HistoricalData>>(
        future: _logsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF2DC867)));
          }
          final logs = snapshot.data!;
          if (logs.isEmpty) {
            return const Center(child: Text('No system logs recorded for this batch.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final log = logs[index];
              return Card(
                child: ListTile(
                  title: Text(_formatDateTime(log.timestamp)),
                  subtitle: Text('pH ${log.pH.toStringAsFixed(2)}  |  ${log.temperature}  |  ${log.waterLevel}  |  TDS ${log.tds.toStringAsFixed(1)}'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SnapshotDetailScreen(
                        data: log,
                        formattedTime: _formatDateTime(log.timestamp),
                        minPh: 5.5,
                        maxPh: 7.0,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
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
    this.maxPh = 7.0,
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
    bool isTdsOptimal = data.tds >= 400 && data.tds <= 900;

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
            Expanded(
              child: _buildStaticCard(
                'TDS', 
                '${data.tds.toStringAsFixed(0)} PPM', 
                isTdsOptimal ? 'Optimal' : 'Warning',
                bgOverride: isTdsOptimal ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0),
                textOverride: isTdsOptimal ? Colors.green : Colors.orange,
              )
            ),
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