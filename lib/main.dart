import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:email_otp/email_otp.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:local_auth/local_auth.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'package:wifi_scan/wifi_scan.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'package:flutter/services.dart';

bool get _supportsBackgroundService =>
  !kIsWeb &&
  !const bool.fromEnvironment('FLUTTER_TEST') &&
  (defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS);

int? _cachedServerTimeOffsetMs;
DateTime? _serverClockAnchorUtc;
Stopwatch? _serverClockStopwatch;

DateTime _philippineTime(DateTime timestamp) =>
    timestamp.toUtc().add(const Duration(hours: 8));

Future<DateTime> getServerNow() async {
  try {
    final snapshot = await FirebaseDatabase.instance
        .ref('.info/serverTimeOffset')
        .get()
        .timeout(const Duration(seconds: 2));
    if (snapshot.value is num) {
      _cachedServerTimeOffsetMs = (snapshot.value as num).round();
      _serverClockAnchorUtc = DateTime.now()
          .toUtc()
          .add(Duration(milliseconds: _cachedServerTimeOffsetMs!));
      _serverClockStopwatch = Stopwatch()..start();
      return _serverClockAnchorUtc!;
    }
  } catch (_) {
    // Continue from the monotonic server-time anchor when offline.
  }

  if (_serverClockAnchorUtc != null && _serverClockStopwatch != null) {
    return _serverClockAnchorUtc!.add(_serverClockStopwatch!.elapsed);
  }
  return DateTime.now().toUtc().add(
    Duration(milliseconds: _cachedServerTimeOffsetMs ?? 0),
  );
}

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
      version: 8,
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
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE historical_logs ADD COLUMN bed1 TEXT');
          await db.execute('ALTER TABLE historical_logs ADD COLUMN bed2 TEXT');
        }
        if (oldVersion < 7) {
          await db.execute('ALTER TABLE historical_logs ADD COLUMN cloudSynced INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 8) {
          await db.execute('ALTER TABLE planting_history ADD COLUMN cloudSynced INTEGER NOT NULL DEFAULT 0');
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
        batchNumber INTEGER,
        bed1 TEXT,
        bed2 TEXT,
        cloudSynced INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE planting_history (
        batchNumber INTEGER PRIMARY KEY,
        startDate TEXT NOT NULL,
        endDate TEXT NOT NULL,
        totalDays INTEGER NOT NULL,
        cloudSynced INTEGER NOT NULL DEFAULT 0
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
  Future<void> insertLog(HistoricalData log, {bool cloudSynced = false}) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert('historical_logs', {
      'timestamp': log.timestamp.toIso8601String(),
      'pH': log.pH,
      'temperature': log.temperature,
      'waterLevel': log.waterLevel,
      'tds': log.tds,
      'batchNumber': log.batchNumber,
      'bed1': log.bed1 != null ? jsonEncode(log.bed1!.toMap()) : null,
      'bed2': log.bed2 != null ? jsonEncode(log.bed2!.toMap()) : null,
      'cloudSynced': cloudSynced ? 1 : 0,
    });
  }

  Future<void> insertLogIfMissing(HistoricalData log, {bool cloudSynced = false}) async {
    final db = await instance.database;
    if (db == null) return;
    final existing = await db.query(
      'historical_logs',
      where: 'timestamp = ? AND batchNumber = ?',
      whereArgs: [log.timestamp.toIso8601String(), log.batchNumber],
      limit: 1,
    );
    if (existing.isEmpty) await insertLog(log, cloudSynced: cloudSynced);
  }

  HistoricalData _logFromRow(Map<String, Object?> row) => HistoricalData(
        timestamp: DateTime.parse(row['timestamp'] as String),
        pH: (row['pH'] as num).toDouble(),
        temperature: row['temperature'] as String,
        waterLevel: row['waterLevel'] as String,
        tds: (row['tds'] as num?)?.toDouble() ?? 0.0,
        batchNumber: row['batchNumber'] as int?,
        bed1: _decodeBedData(row['bed1'] as String?),
        bed2: _decodeBedData(row['bed2'] as String?),
      );

  Future<HistoricalData?> getNextUnsyncedLog() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query(
      'historical_logs',
      where: 'cloudSynced = 0',
      orderBy: 'timestamp ASC',
      limit: 1,
    );
    return result.isEmpty ? null : _logFromRow(result.first);
  }

  Future<void> markLogCloudSynced(DateTime timestamp) async {
    final db = await instance.database;
    if (db == null) return;
    await db.update(
      'historical_logs',
      {'cloudSynced': 1},
      where: 'timestamp = ?',
      whereArgs: [timestamp.toIso8601String()],
    );
  }

  Future<List<HistoricalData>> getLogs() async {
    final db = await instance.database;
    if (db == null) return [];
    final result = await db.query('historical_logs', orderBy: 'timestamp DESC');
    return result.map(_logFromRow).toList();
  }

  Future<List<HistoricalData>> getLogsForBatch(int batchNumber) async {
    final db = await instance.database;
    if (db == null) return [];
    final result = await db.query('historical_logs', where: 'batchNumber = ?', whereArgs: [batchNumber], orderBy: 'timestamp DESC');
    return result.map(_logFromRow).toList();
  }

  // Planting Runs History Queries
  Future<void> insertPlantingRecord(PlantingRecord record, {bool cloudSynced = false}) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert('planting_history', {
      'batchNumber': record.batchNumber,
      'startDate': record.startDate.toIso8601String(),
      'endDate': record.endDate.toIso8601String(),
      'totalDays': record.totalDays,
      'cloudSynced': cloudSynced ? 1 : 0,
    });
  }

  Future<PlantingRecord?> getNextUnsyncedPlantingRecord() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query(
      'planting_history',
      where: 'cloudSynced = 0',
      orderBy: 'batchNumber ASC',
      limit: 1,
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return PlantingRecord(
      batchNumber: row['batchNumber'] as int,
      startDate: DateTime.parse(row['startDate'] as String),
      endDate: DateTime.parse(row['endDate'] as String),
      totalDays: row['totalDays'] as int,
    );
  }

  Future<void> markPlantingRecordCloudSynced(int batchNumber) async {
    final db = await instance.database;
    if (db == null) return;
    await db.update(
      'planting_history',
      {'cloudSynced': 1},
      where: 'batchNumber = ?',
      whereArgs: [batchNumber],
    );
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
      ph: 6.0,
        tds: 0.0,
        waterFull: false,
      );

  factory GrowBedReading.fromMap(Map<String, dynamic> map) {
    final temperature = (map['temp'] is num)
        ? (map['temp'] as num).toDouble()
        : double.tryParse((map['temp'] ?? '25.0').toString()) ?? 25.0;
    final ph = (map['ph'] is num)
        ? (map['ph'] as num).toDouble()
      : double.tryParse((map['ph'] ?? '6.0').toString()) ?? 6.0;
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
  final Map<String, bool> actuatorStates;

  const HydrodeckTelemetry({
    required this.bed1,
    required this.bed2,
    required this.growLightOn,
    required this.actuatorStates,
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
      'ph': wireMap['ph1'] ?? wireMap['bed1']?['ph'] ?? wireMap['set1']?['ph'] ?? 6.0,
      'tds': wireMap['tds1'] ?? wireMap['bed1']?['tds'] ?? wireMap['set1']?['tds'] ?? 0.0,
      'water': wireMap['water1'] ?? wireMap['bed1']?['water'] ?? wireMap['set1']?['water'] ?? 'low',
    };

    final bed2Map = {
      'temp': wireMap['temp2'] ?? wireMap['bed2']?['temp'] ?? wireMap['set2']?['temp'] ?? 25.0,
      'ph': wireMap['ph2'] ?? wireMap['bed2']?['ph'] ?? wireMap['set2']?['ph'] ?? 6.0,
      'tds': wireMap['tds2'] ?? wireMap['bed2']?['tds'] ?? wireMap['set2']?['tds'] ?? 0.0,
      'water': wireMap['water2'] ?? wireMap['bed2']?['water'] ?? wireMap['set2']?['water'] ?? 'low',
    };

    final bed1 = GrowBedReading(
      temperature: _readDouble(bed1Map, 'temp', fallback: 25.0),
      ph: _readDouble(bed1Map, 'ph', fallback: 6.0),
      tds: _readDouble(bed1Map, 'tds', fallback: 0.0),
      waterFull: _readWaterFlag(bed1Map, 'water'),
    );

    final bed2 = GrowBedReading(
      temperature: _readDouble(bed2Map, 'temp', fallback: 25.0),
      ph: _readDouble(bed2Map, 'ph', fallback: 6.0),
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
        'growLight',
      ],
      fallback: false,
    );

    final actuatorStates = {
      for (final name in _actuatorControlKeys.keys)
        name: _readBoolLike(allMap, [name]),
    };

    return HydrodeckTelemetry(
      bed1: bed1,
      bed2: bed2,
      growLightOn: growLightOn,
      actuatorStates: actuatorStates,
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
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'hydrodeck_bg_service',
      initialNotificationTitle: 'Hydrodeck Service Active',
      initialNotificationContent: 'Monitoring ESP32 and logging sensors in background...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
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
  double lastPh = 6.0;
  String lastTemp = "25.0°C";
  String lastWater = "low";
  double lastTds = 0.0;
  bool isConnected = false;
  bool firebaseConnected = false;
  bool backgroundActive = false;
  bool lastGrowLight = false;
  GrowBedReading lastBed1 = GrowBedReading.empty();
  GrowBedReading lastBed2 = GrowBedReading.empty();

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
    backgroundActive = isPlantingActive;

    final logs = await DatabaseHelper.instance.getLogs();
    if (logs.isNotEmpty) {
      lastPh = logs.first.pH;
      lastBed2 = GrowBedReading(
        temperature: double.tryParse(logs.first.temperature.replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 25.0,
        ph: logs.first.pH,
        tds: logs.first.tds,
        waterFull: lastWater == 'full',
      );
      lastTemp = logs.first.temperature;
      lastWater = logs.first.waterLevel == "Water full" ? "full" : "low";
      lastTds = logs.first.tds;
    }
  } catch (_) {}

  service.on('setPlantingState').listen((event) async {
    if (event != null && event['active'] != null) {
      isPlantingActive = event['active'] as bool;
        backgroundActive = isPlantingActive || await hasPendingCloudRecords();
      if (!backgroundActive) service.stopSelf();
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

  service.on('stopService').listen((event) {
    service.stopSelf();
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
      'ph': data['ph1'] ?? data['bed1']?['ph'] ?? 6.0,
      'tds': data['tds1'] ?? data['bed1']?['tds'] ?? 0.0,
      'water': data['water1'] ?? data['bed1']?['water'] ?? 'low',
    };
    final bed2 = {
      'temp': data['temp2'] ?? data['bed2']?['temp'] ?? 25.0,
      'ph': data['ph2'] ?? data['bed2']?['ph'] ?? 6.0,
      'tds': data['tds2'] ?? data['bed2']?['tds'] ?? 0.0,
      'water': data['water2'] ?? data['bed2']?['water'] ?? 'low',
    };

    final bed2Ph = bed2['ph'] is num ? (bed2['ph'] as num).toDouble() : 6.0;
    final bed2Temp = bed2['temp'] is num ? (bed2['temp'] as num).toDouble() : 25.0;
    final bed2Tds = bed2['tds'] is num ? (bed2['tds'] as num).toDouble() : 0.0;
    final bed2Water = bed2['water'] is String ? bed2['water'] as String : 'low';
    final actuators = Map<String, dynamic>.from(data['actuators'] is Map ? data['actuators'] as Map : data);
    final growLightFlag = actuators['growLight'] ?? data['grow_light'] ?? data['growLight'] ?? false;

    return {
      'bed1': bed1,
      'bed2': bed2,
      'growLight': growLightFlag,
      'actuators': {
        for (final name in const ['waterPump1', 'phUp1', 'phDown1', 'nutrient1', 'waterPump2', 'phUp2', 'phDown2', 'nutrient2'])
          name: actuators[name] ?? false,
      },
      'ph': bed2Ph,
      'temp': '${bed2Temp.toStringAsFixed(1)}°C',
      'water': bed2Water,
      'tds': bed2Tds,
    };
  }

  Timer.periodic(const Duration(seconds: 3), (timer) async {
    if (!backgroundActive) return;
    if (isPolling) return; // Skip if previous poll hasn't resolved
    isPolling = true;

    bool found = false;
    String telemetrySource = 'offline';
    String cleanTargetIp = sanitizeHost(targetIp);

    // 1. Fast attempt to primary target IP
    final primaryResult = await fetchStatus(cleanTargetIp, const Duration(milliseconds: 1200));

    if (primaryResult != null) {
      final normalized = normalizeStatusPayload(Map<String, dynamic>.from(primaryResult['data'] as Map));
      final bed1 = GrowBedReading.fromMap(normalized['bed1'] as Map<String, dynamic>);
      final bed2 = GrowBedReading.fromMap(normalized['bed2'] as Map<String, dynamic>);

      lastBed1 = bed1;
      lastBed2 = bed2;
      lastGrowLight = HydrodeckTelemetry._readBoolLike({'growLight': normalized['growLight']}, const ['growLight']);
      lastPh = bed2.ph;
      lastTemp = '${bed2.temperature.toStringAsFixed(1)}°C';
      lastTds = bed2.tds;
      lastWater = bed2.waterFull ? 'full' : 'low';

      service.invoke('telemetryUpdate', {
        'isConnected': true,
        'ip': cleanTargetIp,
        'ph': lastPh,
        'temp': lastTemp,
        'water': lastWater,
        'tds': lastTds,
        'bed1': bed1.toMap(),
        'bed2': bed2.toMap(),
        'growLight': normalized['growLight'] ?? false,
        'actuators': normalized['actuators'],
        'source': 'local',
      });

      targetIp = cleanTargetIp;
      isConnected = true;
      found = true;
      telemetrySource = 'local';
    }

    // 2. Concurrently probe fallback local hosts if primary target failed
    if (!found) {
      final List<String> fallbackHosts = [
        "hydrodeck.local",
        "192.168.4.1",
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
          final bed1 = GrowBedReading.fromMap(normalized['bed1'] as Map<String, dynamic>);
          final bed2 = GrowBedReading.fromMap(normalized['bed2'] as Map<String, dynamic>);

          lastBed1 = bed1;
          lastBed2 = bed2;
          lastGrowLight = HydrodeckTelemetry._readBoolLike({'growLight': normalized['growLight']}, const ['growLight']);
          lastPh = bed2.ph;
          lastTemp = '${bed2.temperature.toStringAsFixed(1)}°C';
          lastTds = bed2.tds;
          lastWater = bed2.waterFull ? 'full' : 'low';

          service.invoke('telemetryUpdate', {
            'isConnected': true,
            'ip': host,
            'ph': lastPh,
            'temp': lastTemp,
            'water': lastWater,
            'tds': lastTds,
            'bed1': bed1.toMap(),
            'bed2': bed2.toMap(),
            'growLight': normalized['growLight'] ?? false,
            'actuators': normalized['actuators'],
            'source': 'local',
          });

          targetIp = host;
          DatabaseHelper.instance.saveActiveIp(targetIp);
          isConnected = true;
          found = true;
          telemetrySource = 'local';
          break;
        }
      }
    }

    // 3. Fallback to Firebase Realtime Database for Remote Network Connection
    if (!found) {
      firebaseConnected = false;
      try {
        final dbRef = FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: "https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/",
        ).ref('hydrodeck');

        final snapshot = await dbRef.get().timeout(const Duration(milliseconds: 2500));
        if (snapshot.exists && snapshot.value != null) {
          final data = Map<String, dynamic>.from(snapshot.value as Map);
          final telemetry = HydrodeckTelemetry.fromJson(data);
          lastBed1 = telemetry.bed1;
          lastBed2 = telemetry.bed2;
          lastGrowLight = telemetry.growLightOn;
          lastPh = lastBed2.ph;
          lastTemp = '${lastBed2.temperature.toStringAsFixed(1)}°C';
          lastTds = lastBed2.tds;
          lastWater = lastBed2.waterFull ? 'full' : 'low';
          firebaseConnected = true;
          final lastSeen = data['lastSeen'];
          final heartbeatMillis = lastSeen is num
              ? lastSeen.toInt()
              : int.tryParse(lastSeen?.toString() ?? '');
          final heartbeatFresh = heartbeatMillis != null &&
              DateTime.now().difference(
                DateTime.fromMillisecondsSinceEpoch(heartbeatMillis),
              ).inSeconds <= 15;
          isConnected = data['wifiConnected'] == true &&
              data['firebaseReady'] == true &&
              heartbeatFresh;
          found = true;
            telemetrySource = 'firebase';
        }
      } catch (_) {}
    }

    if (!found) {
      isConnected = false;
      telemetrySource = 'offline';
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
      'firebaseConnected': firebaseConnected,
      'source': telemetrySource,
      'ip': targetIp,
      'ph': lastPh,
      'temp': lastTemp,
      'water': lastWater,
      'tds': lastTds,
      'bed1': lastBed1.toMap(),
      'bed2': lastBed2.toMap(),
      'growLight': lastGrowLight,
    });

    isPolling = false;
  });

  String? lastSnapshotMinute;
  var minuteTaskScheduled = false;

  Future<void> scheduleNextMinuteTask() async {
    if (minuteTaskScheduled || !backgroundActive) return;
    minuteTaskScheduled = true;
    try {
      final now = await getServerNow();
        // Save and upload historical snapshots on five-minute local-time boundaries.
        final philippinesNow = _philippineTime(now);
        final nextFiveMinute = (philippinesNow.minute ~/ 5 + 1) * 5;
        final nextBoundary = DateTime.utc(
          philippinesNow.year,
          philippinesNow.month,
          philippinesNow.day,
          philippinesNow.hour,
          nextFiveMinute,
        );
        final wait = nextBoundary.difference(philippinesNow);
      Timer(wait.isNegative ? Duration.zero : wait, () async {
        try {
          if (!backgroundActive) return;
          final serverNow = await getServerNow();
          final minuteKey = _minuteBucketKey(serverNow);
          if (isPlantingActive && minuteKey != lastSnapshotMinute) {
            lastSnapshotMinute = minuteKey;
            final snapshot = HistoricalData(
              timestamp: serverNow,
              pH: lastPh,
              temperature: lastTemp,
              waterLevel: lastWater == 'full' ? 'Water full' : 'Needs water',
              tds: lastTds,
              batchNumber: activeBatchNumber,
              bed1: lastBed1,
              bed2: lastBed2,
            );
            await DatabaseHelper.instance.insertLog(snapshot);
            service.invoke('newSnapshotLogged', {
              'timestamp': snapshot.timestamp.toIso8601String(),
              'pH': snapshot.pH,
              'temperature': snapshot.temperature,
              'waterLevel': snapshot.waterLevel,
              'tds': snapshot.tds,
              'batchNumber': snapshot.batchNumber,
              'bed1': snapshot.bed1?.toMap(),
              'bed2': snapshot.bed2?.toMap(),
            });
          }
            await uploadNextUnsyncedRecord();
            if (!isPlantingActive && !await hasPendingCloudRecords()) {
            backgroundActive = false;
            service.stopSelf();
          }
        } catch (_) {
          // Local logs remain queued if the network or Firestore is unavailable.
        } finally {
          minuteTaskScheduled = false;
          if (backgroundActive) unawaited(scheduleNextMinuteTask());
        }
      });
    } catch (_) {
      minuteTaskScheduled = false;
      Timer(const Duration(seconds: 5), () => unawaited(scheduleNextMinuteTask()));
    }
  }

  unawaited(scheduleNextMinuteTask());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true);
  } catch (_) {}

  EmailOTP.config(
    appName: 'Hydrodeck',
    appEmail: 'hydrodecknt@gmail.com',
    otpLength: 6,
    otpType: OTPType.numeric,
    expiry: 10 * 60 * 1000,
  );
  EmailOTP.setTemplate(
    template: '''
<!doctype html>
<html lang="en">
  <body style="margin:0;background:#f5f8f5;font-family:Arial,sans-serif;color:#232323;">
    <div style="max-width:520px;margin:32px auto;background:#ffffff;border-radius:12px;overflow:hidden;">
      <div style="padding:24px;background:#2dc867;color:#ffffff;font-size:22px;font-weight:700;">{{appName}}</div>
      <div style="padding:28px 24px;">
        <p style="margin:0 0 16px;font-size:16px;">Dear user,</p>
        <p style="margin:0 0 16px;font-size:16px;">Your One-Time Password (OTP) is:</p>
        <div style="padding:18px;background:#e8f7ed;border-radius:8px;color:#16783a;text-align:center;font-size:32px;font-weight:700;letter-spacing:6px;">{{otp}}</div>
        <p style="margin:20px 0 0;color:#666;font-size:13px;">Thank you for using Hydrodeck!</p>
        <p style="margin:20px 0 0;color:#666;font-size:12px;">This code expires in 10 minutes. If you did not request it, you can ignore this email.</p>
      </div>
      <div style="padding:16px 24px;border-top:1px solid #e7ece8;color:#7a7a7a;font-size:12px;">Hydrodeck · {{year}}</div>
    </div>
  </body>
</html>
''',
  );
  EmailOTP.setSMTP(
    emailPort: EmailPort.port587,
    secureType: SecureType.tls,
    host: 'smtp.gmail.com',
    username: 'hydrodecknt@gmail.com',
    password: 'bctm hpcn krjt ffgy',
  );
  if (_supportsBackgroundService) await NotificationHelper.init();
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
      home: const AuthGatekeeper(),
    );
  }
}

class AuthGatekeeper extends StatefulWidget {
  const AuthGatekeeper({super.key});

  @override
  State<AuthGatekeeper> createState() => _AuthGatekeeperState();
}

class _AuthGatekeeperState extends State<AuthGatekeeper> {
  bool _loading = true;
  bool _showSignup = true;
  User? _user;
  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      final lastSignIn = user?.metadata.lastSignInTime;
      final sessionValid = user != null &&
          lastSignIn != null &&
          DateTime.now().difference(lastSignIn).inDays < 30;
      if (!sessionValid && user != null) {
        unawaited(FirebaseAuth.instance.signOut());
      }
      if (mounted) {
        setState(() {
          _user = sessionValid ? user : null;
          _loading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  void _authenticated(User user) {
    setState(() => _user = user);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: Color(0xFF2DC867))));
    if (_user != null) return const MainGatekeeper();
    return _showSignup
        ? SignupScreen(onLogin: () => setState(() => _showSignup = false), onAuthenticated: _authenticated)
        : LoginScreen(onSignup: () => setState(() => _showSignup = true), onAuthenticated: _authenticated);
  }
}

class SignupScreen extends StatefulWidget {
  final VoidCallback onLogin;
  final ValueChanged<User> onAuthenticated;
  const SignupScreen({super.key, required this.onLogin, required this.onAuthenticated});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() { _email.dispose(); _phone.dispose(); _password.dispose(); _confirm.dispose(); _pin.dispose(); super.dispose(); }

  Future<void> _signup() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    final phone = _phone.text.trim();
    if (!RegExp(r'^09\d{9}$').hasMatch(phone)) {
      setState(() => _error = 'Phone number must be 11 digits and start with 09.');
      return;
    }
    if (_password.text.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    if (_pin.text != '6967') {
      setState(() => _error = 'The access PIN is incorrect.');
      _pin.clear();
      return;
    }

    setState(() { _busy = true; _error = null; });
    try {
      final sent = await EmailOTP.sendOTP(email: email);
      if (!sent) {
        setState(() => _error = EmailOTP.lastError ?? 'Could not send the OTP.');
        return;
      }

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => OtpVerificationScreen(
              email: email,
              flow: 'signup',
              phone: phone,
              password: _password.text,
              pin: _pin.text,
              onLogin: widget.onLogin,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthFormScaffold(
    title: 'Create your account', subtitle: 'Set up secure access to Hydrodeck', error: _error, busy: _busy,
    fields: [
      _field(_email, 'Email', Icons.email_outlined, keyboard: TextInputType.emailAddress),
      _field(_phone, 'Phone number', Icons.phone_outlined, keyboard: TextInputType.phone, maxLength: 11),
      _field(_password, 'Password', Icons.lock_outline, obscure: true),
      _field(_confirm, 'Confirm password', Icons.lock_outline, obscure: true),
      _field(_pin, 'Hydrodeck access PIN', Icons.key_outlined, keyboard: TextInputType.number, obscure: true),
    ], actionLabel: 'Sign up', onAction: _signup, footer: TextButton(onPressed: widget.onLogin, child: const Text('Already have an account? Log in')),
  );
}

class LoginScreen extends StatefulWidget {
  final VoidCallback onSignup;
  final ValueChanged<User> onAuthenticated;
  const LoginScreen({super.key, required this.onSignup, required this.onAuthenticated});
  @override State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() { _email.dispose(); _password.dispose(); super.dispose(); }

  Future<void> _login() async {
    setState(() { _busy = true; _error = null; });
    try {
      final result = await FirebaseAuth.instance.signInWithEmailAndPassword(email: _email.text.trim(), password: _password.text);
      if (mounted) widget.onAuthenticated(result.user!);
    } on FirebaseAuthException catch (e) { setState(() => _error = e.message ?? 'Could not log in.'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) => _AuthFormScaffold(
    title: 'Welcome back', subtitle: 'Log in to continue to Hydrodeck', error: _error, busy: _busy,
    fields: [_field(_email, 'Email', Icons.email_outlined, keyboard: TextInputType.emailAddress), _field(_password, 'Password', Icons.lock_outline, obscure: true)],
    actionLabel: 'Log in', onAction: _login,
    footer: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(onPressed: widget.onSignup, child: const Text('Create a new account')),
        TextButton(
          onPressed: _busy ? null : () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const ForgotPasswordScreen()),
            );
          },
          child: const Text('Forgot password?'),
        ),
      ],
    ),
  );
}

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }

    setState(() { _busy = true; _error = null; });
    try {
      final sent = await EmailOTP.sendOTP(email: email);
      if (!sent) {
        setState(() => _error = EmailOTP.lastError ?? 'Could not send the OTP.');
        return;
      }
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => OtpVerificationScreen(
              email: email,
              flow: 'forgot',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Forgot Password'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Enter your email address',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'We will send a 6-digit OTP to confirm the account before starting the password reset process.',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 18),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
                  ),
                ),
              ElevatedButton(
                onPressed: _busy ? null : _sendOtp,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2DC867),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(_busy ? 'Sending OTP...' : 'Send OTP'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OtpVerificationScreen extends StatefulWidget {
  final String email;
  final String flow;
  final String? phone;
  final String? password;
  final String? pin;
  final VoidCallback? onLogin;
  final VoidCallback? onDeleteConfirmed;

  const OtpVerificationScreen({
    super.key,
    required this.email,
    required this.flow,
    this.phone,
    this.password,
    this.pin,
    this.onLogin,
    this.onDeleteConfirmed,
  });

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  final _otpController = TextEditingController();
  bool _busy = false;
  String? _error;
  DateTime? _resendAvailableAt;

  @override
  void initState() {
    super.initState();
    _resendAvailableAt = DateTime.now().add(const Duration(minutes: 3));
  }

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  bool get _canResend => _resendAvailableAt == null || DateTime.now().isAfter(_resendAvailableAt!);

  String get _resendLabel {
    if (_canResend) return 'Send another code';
    final remaining = _resendAvailableAt!.difference(DateTime.now());
    final seconds = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final minutes = remaining.inMinutes.toString().padLeft(2, '0');
    return 'Send another code in $minutes:$seconds';
  }

  Future<void> _resendCode() async {
    if (!_canResend) return;
    setState(() { _busy = true; _error = null; });
    try {
      final sent = widget.flow == 'forgot'
          ? await EmailOTP.resendOTP(email: widget.email)
          : await EmailOTP.resendOTP(email: widget.email);
      if (!sent) {
        setState(() => _error = EmailOTP.lastError ?? 'Could not send another code.');
        return;
      }
      _resendAvailableAt = DateTime.now().add(const Duration(minutes: 3));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A new OTP has been sent.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyAndContinue() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6 || !RegExp(r'^\d{6}$').hasMatch(otp)) {
      setState(() => _error = 'Enter the 6-digit OTP sent to your email.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final isValid = EmailOTP.verifyOTP(otp: otp);
      if (!isValid) {
        setState(() => _error = EmailOTP.isOtpExpired() ? 'The OTP has expired. Please request a new one.' : 'Invalid OTP. Please try again.');
        return;
      }

      if (widget.flow == 'signup') {
        final password = widget.password ?? '';
        final phone = widget.phone ?? '';
        if (password.isEmpty || phone.isEmpty) {
          setState(() => _error = 'Signup data is missing. Please try again.');
          return;
        }

        final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: widget.email,
          password: password,
        );

        await FirebaseDatabase.instance.ref('users/${credential.user!.uid}').set({
          'email': widget.email,
          'phone': phone,
          'createdAt': ServerValue.timestamp,
        });

        await FirebaseAuth.instance.signOut();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Account created successfully. Please log in.')),
          );
          Navigator.of(context).popUntil((route) => route.isFirst);
          if (widget.onLogin != null) widget.onLogin!();
        }
        return;
      }

      if (widget.flow == 'delete') {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) {
          setState(() => _error = 'You need to be signed in to delete your account.');
          return;
        }

        DateTime scheduledAt;
        try {
          scheduledAt = (await getServerNow()).add(const Duration(days: 7));
        } catch (e) {
          if (mounted) {
            setState(() => _error = 'Failed to schedule account deletion. Please try again later.');
          }
          return;
        }
        await FirebaseDatabase.instance.ref('users/${user.uid}').update({
          'deleteRequestedAt': ServerValue.timestamp,
          'deleteScheduledAt': scheduledAt.toUtc().toIso8601String(),
          'accountStatus': 'pending_delete',
        });
        await FirebaseAuth.instance.signOut();

        if (mounted) {
          if (widget.onDeleteConfirmed != null) widget.onDeleteConfirmed!();
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        return;
      }

      await FirebaseAuth.instance.sendPasswordResetEmail(email: widget.email);

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => PasswordResetInstructionsScreen(
              email: widget.email,
            ),
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? 'Could not complete the request.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.flow == 'signup' ? 'Verify Email' : 'Verify Reset OTP'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.flow == 'signup'
                    ? 'Enter the 6-digit code sent to your email'
                    : 'Enter the OTP sent to your email to continue the reset flow',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                widget.email,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _otpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'OTP code',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
              const SizedBox(height: 18),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
                  ),
                ),
              ElevatedButton(
                onPressed: _busy ? null : _verifyAndContinue,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(_busy ? 'Verifying...' : widget.flow == 'signup' ? 'Verify & Create Account' : 'Verify OTP'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: (_busy || !_canResend) ? null : _resendCode,
                child: Text(_resendLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PasswordResetInstructionsScreen extends StatelessWidget {
  final String email;

  const PasswordResetInstructionsScreen({super.key, required this.email});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.mark_email_unread_outlined, size: 72, color: Color(0xFF2DC867)),
              const SizedBox(height: 20),
              const Text(
                'Password reset link sent',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                'A secure password reset email has been sent to $email. Open it and follow the instructions to create a new password.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2DC867),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Back to login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _field(TextEditingController controller, String label, IconData icon, {bool obscure = false, TextInputType? keyboard, int? maxLength}) {
  if (obscure) {
    return _PasswordVisibilityField(controller: controller, label: label, icon: icon);
  }
  return TextField(
    controller: controller,
    keyboardType: keyboard,
    maxLength: maxLength,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

class _PasswordVisibilityField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;

  const _PasswordVisibilityField({
    required this.controller,
    required this.label,
    required this.icon,
  });

  @override
  State<_PasswordVisibilityField> createState() => _PasswordVisibilityFieldState();
}

class _PasswordVisibilityFieldState extends State<_PasswordVisibilityField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: Icon(widget.icon),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          suffixIcon: IconButton(
            tooltip: _obscure ? 'Show password' : 'Hide password',
            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      );
}

class _AuthFormScaffold extends StatelessWidget {
  final String title, subtitle, actionLabel; final String? error; final bool busy; final List<Widget> fields; final VoidCallback onAction; final Widget footer;
  const _AuthFormScaffold({required this.title, required this.subtitle, required this.actionLabel, required this.error, required this.busy, required this.fields, required this.onAction, required this.footer});
  @override Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('HYDRODECK', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 2)), const SizedBox(height: 8), Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)), const SizedBox(height: 28), Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), const SizedBox(height: 18),
    ...fields.expand((field) => [field, const SizedBox(height: 12)]), if (error != null) Text(error!, style: const TextStyle(color: Colors.red)), const SizedBox(height: 12), ElevatedButton(onPressed: busy ? null : onAction, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2DC867), foregroundColor: Colors.white, minimumSize: const Size.fromHeight(52)), child: Text(busy ? 'Please wait...' : actionLabel)), Center(child: footer),
  ]))))));
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _phoneController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadUserProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _emailController.text = user.email ?? '';
    final phoneValue = await FirebaseDatabase.instance
        .ref('users/${user.uid}/phone')
        .get();
    if (mounted) {
      _phoneController.text = phoneValue.value?.toString() ?? '';
    }
  }

  Future<void> _saveProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _message = 'You need to be signed in to update your profile.');
      return;
    }

    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    final newPassword = _newPasswordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _message = 'Enter a valid email address.');
      return;
    }

    if (!RegExp(r'^09\d{9}$').hasMatch(phone)) {
      setState(() => _message = 'Phone number must be 11 digits and start with 09.');
      return;
    }

    if ((newPassword.isNotEmpty || confirmPassword.isNotEmpty) && newPassword.length < 6) {
      setState(() => _message = 'New password must be at least 6 characters.');
      return;
    }

    if (newPassword != confirmPassword) {
      setState(() => _message = 'New password and confirm password must match.');
      return;
    }

    if ((email != user.email || newPassword.isNotEmpty) && _currentPasswordController.text.trim().isEmpty) {
      setState(() => _message = 'Enter your current password to update email or password.');
      return;
    }

    setState(() { _busy = true; _message = null; });
    try {
      if (email != user.email || newPassword.isNotEmpty) {
        final credential = EmailAuthProvider.credential(
          email: user.email ?? email,
          password: _currentPasswordController.text.trim(),
        );
        await user.reauthenticateWithCredential(credential);
      }

      if (email != user.email) {
        await user.verifyBeforeUpdateEmail(email);
      }

      if (newPassword.isNotEmpty) {
        await user.updatePassword(newPassword);
      }

      await FirebaseDatabase.instance.ref('users/${user.uid}').update({
        'email': email,
        'phone': phone,
      });

      await user.reload();

      if (mounted) {
        setState(() {
          _message = 'Profile updated successfully.';
          _currentPasswordController.clear();
          _newPasswordController.clear();
          _confirmPasswordController.clear();
        });
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _message = e.message ?? 'Could not update your profile.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not update your profile.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await FirebaseAuth.instance.signOut();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _requestDeleteAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null || user.email!.isEmpty) {
      setState(() => _message = 'You need to be signed in to delete your account.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This will schedule account deletion in 7 days. A confirmation email will be sent to your registered email address.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() { _busy = true; _message = null; });
    try {
      final sent = await EmailOTP.sendOTP(email: user.email!);
      if (!sent) {
        throw Exception(EmailOTP.lastError ?? 'Could not send the confirmation email.');
      }
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => OtpVerificationScreen(
              email: user.email!,
              flow: 'delete',
              onDeleteConfirmed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Account deletion scheduled. You can still use the app until the 7-day period ends.')),
                );
              },
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not send the confirmation email. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Edit your account details',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Changing the email address sends a verification email to the new address before it becomes active.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 16),
              _PasswordVisibilityField(controller: _currentPasswordController, label: 'Current password', icon: Icons.lock_outline),
              const SizedBox(height: 16),
              _PasswordVisibilityField(controller: _newPasswordController, label: 'New password', icon: Icons.lock_reset_outlined),
              const SizedBox(height: 16),
              _PasswordVisibilityField(controller: _confirmPasswordController, label: 'Confirm new password', icon: Icons.lock_reset_outlined),
              const SizedBox(height: 24),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _message!,
                    style: TextStyle(
                      color: _message!.contains('success') ? Colors.green : Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ElevatedButton(
                onPressed: _busy ? null : _saveProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2DC867),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(_busy ? 'Saving...' : 'Save Changes'),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _signOut,
                icon: const Icon(Icons.logout_outlined),
                label: const Text('Sign out'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black87,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _requestDeleteAccount,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete account'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ],
          ),
        ),
      ),
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
  final GrowBedReading? bed1;
  final GrowBedReading? bed2;

  HistoricalData({
    required this.timestamp,
    required this.pH,
    required this.temperature,
    required this.waterLevel,
    required this.tds,
    this.batchNumber,
    this.bed1,
    this.bed2,
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

class ActivePlantingSession {
  final int batchNumber;
  final DateTime startDate;

  const ActivePlantingSession({required this.batchNumber, required this.startDate});
}

class CloudHistory {
  final List<PlantingRecord> runs;
  final List<HistoricalData> logs;
  final ActivePlantingSession? activeSession;
  final bool activeStateKnown;

  const CloudHistory({
    required this.runs,
    required this.logs,
    this.activeSession,
    this.activeStateKnown = false,
  });
}

DateTime? _parseFirebaseTimestamp(dynamic value) {
  if (value is Timestamp) return value.toDate().toUtc();
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  if (value is String) {
    return DateTime.tryParse(value)?.toUtc();
  }
  return null;
}

const String _sharedHydrodeckSystemId = 'hydrodeck';
const Map<String, String> _actuatorControlKeys = {
  'waterPump1': 'bed1_water',
  'phUp1': 'bed1_ph_up',
  'phDown1': 'bed1_ph_down',
  'nutrient1': 'bed1_nutrient',
  'waterPump2': 'bed2_water',
  'phUp2': 'bed2_ph_up',
  'phDown2': 'bed2_ph_down',
  'nutrient2': 'bed2_nutrient',
  'growLight': 'grow_light',
};

String _minuteBucketKey(DateTime timestamp) {
  final time = _philippineTime(timestamp);
  return '${time.year}${time.month.toString().padLeft(2, '0')}${time.day.toString().padLeft(2, '0')}_'
      '${time.hour.toString().padLeft(2, '0')}${time.minute.toString().padLeft(2, '0')}';
}

GrowBedReading? _decodeBedData(dynamic value) {
  if (value == null) return null;
  if (value is GrowBedReading) return value;
  if (value is Map) {
    return GrowBedReading.fromMap(Map<String, dynamic>.from(value));
  }
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return GrowBedReading.fromMap(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
  }
  return null;
}

Future<CloudHistory> downloadCloudHistory() async {
  final runs = <PlantingRecord>[];
  final logs = <HistoricalData>[];
  final seenRuns = <int>{};
  final seenLogs = <String>{};
  ActivePlantingSession? activeSession;
  var activeStateKnown = false;

  if (FirebaseAuth.instance.currentUser != null) {
    try {
      final system = FirebaseFirestore.instance
          .collection('hydrodeckSystems')
          .doc(_sharedHydrodeckSystemId);
      final activeDocumentFuture = system
          .collection('metadata')
          .doc('activePlanting')
          .get();
      try {
        final activeDocument = await activeDocumentFuture.timeout(const Duration(seconds: 4));
        activeStateKnown = activeDocument.exists;
        final activeData = activeDocument.data();
        if (activeData?['active'] == true) {
          final batch = (activeData?['batchNumber'] as num?)?.toInt();
          final start = _parseFirebaseTimestamp(activeData?['startedAt'] ?? activeData?['startDate']);
          if (batch != null && start != null) {
            activeSession = ActivePlantingSession(batchNumber: batch, startDate: start);
          }
        }
      } catch (_) {}

      try {
        final snapshots = await Future.wait([
          system.collection('plantingRuns').get(),
          system.collection('minuteLogs').get(),
        ]).timeout(const Duration(seconds: 6));
        for (final document in snapshots[0].docs) {
          final map = document.data();
          final batch = (map['batchNumber'] as num?)?.toInt() ?? int.tryParse(document.id);
          final start = _parseFirebaseTimestamp(map['startedAt'] ?? map['startDate']);
          final end = _parseFirebaseTimestamp(map['endedAt'] ?? map['endDate']);
          final days = (map['totalDays'] as num?)?.toInt() ?? 1;
          if (batch != null && start != null && end != null && seenRuns.add(batch)) {
            runs.add(PlantingRecord(
              batchNumber: batch,
              startDate: start,
              endDate: end,
              totalDays: days,
            ));
          }
        }

        for (final document in snapshots[1].docs) {
          final map = document.data();
          final timestamp = _parseFirebaseTimestamp(map['sampleTime'] ?? map['timestamp']);
          if (timestamp == null) continue;
          final batch = (map['batchNumber'] as num?)?.toInt();
          final dedupeKey = '${batch ?? 0}|${document.id}';
          if (!seenLogs.add(dedupeKey)) continue;
          logs.add(HistoricalData(
            timestamp: timestamp,
            pH: (map['pH'] as num?)?.toDouble() ?? 0,
            temperature: map['temperature']?.toString() ?? '',
            waterLevel: map['waterLevel']?.toString() ?? 'Needs water',
            tds: (map['tds'] as num?)?.toDouble() ?? 0,
            batchNumber: batch,
            bed1: _decodeBedData(map['bed1']),
            bed2: _decodeBedData(map['bed2']),
          ));
        }
      } catch (_) {}
    } catch (_) {
      // Keep local history usable while Firestore is unavailable.
    }
  }

  final user = FirebaseAuth.instance.currentUser;
  if (user != null) {
    try {
      final legacyRoot = FirebaseDatabase.instance.ref('users/${user.uid}');
      final snapshots = await Future.wait([
        legacyRoot.child('plantingRuns').get(),
        legacyRoot.child('plantingLogs').get(),
      ]).timeout(const Duration(seconds: 4));

      final runsValue = snapshots[0].value;
      if (runsValue is Map) {
        for (final raw in runsValue.values) {
          if (raw is! Map) continue;
          final map = Map<String, dynamic>.from(raw);
          final start = _parseFirebaseTimestamp(map['startDate']);
          final end = _parseFirebaseTimestamp(map['endDate']);
          final batch = int.tryParse('${map['batchNumber'] ?? ''}');
          final days = int.tryParse('${map['totalDays'] ?? ''}');
          if (start != null && end != null && batch != null && days != null && seenRuns.add(batch)) {
            runs.add(PlantingRecord(batchNumber: batch, startDate: start, endDate: end, totalDays: days));
          }
        }
      }

      final logsValue = snapshots[1].value;
      if (logsValue is Map) {
        for (final batchEntry in logsValue.entries) {
          final batch = int.tryParse('${batchEntry.key}');
          final batchLogs = batchEntry.value;
          if (batchLogs is! Map) continue;
          for (final logEntry in batchLogs.entries) {
            final raw = logEntry.value;
            if (raw is! Map) continue;
            final map = Map<String, dynamic>.from(raw);
            final timestamp = _parseFirebaseTimestamp(map['timestamp']);
            if (timestamp == null) continue;
            final logBatch = int.tryParse('${map['batchNumber'] ?? batch ?? 0}');
            final dedupeKey = '${logBatch ?? 0}|${timestamp.toIso8601String()}';
            if (!seenLogs.add(dedupeKey)) continue;
            logs.add(HistoricalData(
              timestamp: timestamp,
              pH: double.tryParse('${map['pH'] ?? 0}') ?? 0,
              temperature: '${map['temperature'] ?? ''}',
              waterLevel: '${map['waterLevel'] ?? 'Needs water'}',
              tds: double.tryParse('${map['tds'] ?? 0}') ?? 0,
              batchNumber: logBatch,
              bed1: _decodeBedData(map['bed1']),
              bed2: _decodeBedData(map['bed2']),
            ));
          }
        }
      }
    } catch (_) {
      // Older per-user Realtime Database records remain a read fallback.
    }
  }

  runs.sort((a, b) => a.batchNumber.compareTo(b.batchNumber));
  logs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return CloudHistory(
    runs: runs,
    logs: logs,
    activeSession: activeSession,
    activeStateKnown: activeStateKnown,
  );
}

Future<void> uploadHistoricalLog(HistoricalData snapshot) async {
  if (FirebaseAuth.instance.currentUser == null) return;
  final serverNow = await getServerNow();
  final minuteKey = _minuteBucketKey(serverNow);
  final minuteDoc = FirebaseFirestore.instance
      .collection('hydrodeckSystems')
      .doc(_sharedHydrodeckSystemId)
      .collection('minuteLogs')
      .doc(minuteKey);
  await FirebaseFirestore.instance.runTransaction((transaction) async {
    final existing = await transaction.get(minuteDoc);
    if (existing.exists) return;
    transaction.set(minuteDoc, {
      'systemId': _sharedHydrodeckSystemId,
      'minuteKey': minuteKey,
      'sampleTime': Timestamp.fromDate(snapshot.timestamp.toUtc()),
      'batchNumber': snapshot.batchNumber,
      'timestamp': FieldValue.serverTimestamp(),
      'pH': snapshot.pH,
      'temperature': snapshot.temperature,
      'waterLevel': snapshot.waterLevel,
      'tds': snapshot.tds,
      'bed1': snapshot.bed1?.toMap(),
      'bed2': snapshot.bed2?.toMap(),
    });
  });
}

Future<void> uploadNextUnsyncedRecord() async {
  final run = await DatabaseHelper.instance.getNextUnsyncedPlantingRecord();
  if (run != null) {
    if (await uploadPlantingRecord(run)) {
      await DatabaseHelper.instance.markPlantingRecordCloudSynced(run.batchNumber);
    }
    return;
  }

  final log = await DatabaseHelper.instance.getNextUnsyncedLog();
  if (log == null) return;
  await uploadHistoricalLog(log);
  await DatabaseHelper.instance.markLogCloudSynced(log.timestamp);
}

Future<bool> hasPendingCloudRecords() async {
  if (await DatabaseHelper.instance.getNextUnsyncedPlantingRecord() != null) return true;
  return await DatabaseHelper.instance.getNextUnsyncedLog() != null;
}

Future<void> syncLegacyActivePlantingSession(ActivePlantingSession session) async {
  if (FirebaseAuth.instance.currentUser == null) return;
  final system = FirebaseFirestore.instance
      .collection('hydrodeckSystems')
      .doc(_sharedHydrodeckSystemId);
  final activeRef = system.collection('metadata').doc('activePlanting');
  final counterRef = system.collection('metadata').doc('counters');
  try {
    await FirebaseFirestore.instance.runTransaction<void>((transaction) async {
      final activeSnapshot = await transaction.get(activeRef);
      if (activeSnapshot.exists) return;
      final counterSnapshot = await transaction.get(counterRef);
      final stored = (counterSnapshot.data()?['lastBatchNumber'] as num?)?.toInt() ?? 0;
      transaction.set(counterRef, {
        'lastBatchNumber': stored < session.batchNumber ? session.batchNumber : stored,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      transaction.set(activeRef, {
        'active': true,
        'status': 'active',
        'systemId': _sharedHydrodeckSystemId,
        'batchNumber': session.batchNumber,
        'startedAt': Timestamp.fromDate(session.startDate.toUtc()),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  } catch (_) {}
}

Future<ActivePlantingSession> startOrResumePlanting(
  DateTime now,
  int fallbackNumber,
) async {
  if (FirebaseAuth.instance.currentUser == null) {
    return ActivePlantingSession(batchNumber: fallbackNumber, startDate: now);
  }
  final system = FirebaseFirestore.instance
      .collection('hydrodeckSystems')
      .doc(_sharedHydrodeckSystemId);
  final activeRef = system.collection('metadata').doc('activePlanting');
  final counterRef = system.collection('metadata').doc('counters');
  try {
    return await FirebaseFirestore.instance.runTransaction<ActivePlantingSession>((transaction) async {
      final activeSnapshot = await transaction.get(activeRef);
      final activeData = activeSnapshot.data();
      if (activeData?['active'] == true) {
        final existingBatch = (activeData?['batchNumber'] as num?)?.toInt();
        final existingStart = _parseFirebaseTimestamp(activeData?['startedAt'] ?? activeData?['startDate']);
        if (existingBatch != null && existingStart != null) {
          return ActivePlantingSession(batchNumber: existingBatch, startDate: existingStart);
        }
      }

      final counterSnapshot = await transaction.get(counterRef);
      final stored = (counterSnapshot.data()?['lastBatchNumber'] as num?)?.toInt() ?? 0;
      final batchNumber = stored >= fallbackNumber ? stored + 1 : fallbackNumber;
      transaction.set(counterRef, {
        'lastBatchNumber': batchNumber,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      transaction.set(activeRef, {
        'active': true,
        'status': 'active',
        'systemId': _sharedHydrodeckSystemId,
        'batchNumber': batchNumber,
        'startedAt': Timestamp.fromDate(now.toUtc()),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return ActivePlantingSession(batchNumber: batchNumber, startDate: now);
    });
  } catch (_) {
    return ActivePlantingSession(batchNumber: fallbackNumber, startDate: now);
  }
}

Future<bool> uploadPlantingRecord(PlantingRecord record) async {
  if (FirebaseAuth.instance.currentUser == null) return false;
  final runRef = FirebaseFirestore.instance
      .collection('hydrodeckSystems')
      .doc(_sharedHydrodeckSystemId)
      .collection('plantingRuns')
      .doc(record.batchNumber.toString());
  final activeRef = FirebaseFirestore.instance
      .collection('hydrodeckSystems')
      .doc(_sharedHydrodeckSystemId)
      .collection('metadata')
      .doc('activePlanting');
  return FirebaseFirestore.instance.runTransaction<bool>((transaction) async {
    final existing = await transaction.get(runRef);
    final active = await transaction.get(activeRef);
    if (!existing.exists) {
      transaction.set(runRef, {
        'systemId': _sharedHydrodeckSystemId,
        'batchNumber': record.batchNumber,
        'startedAt': Timestamp.fromDate(record.startDate.toUtc()),
        'endedAt': Timestamp.fromDate(record.endDate.toUtc()),
        'uploadedAt': FieldValue.serverTimestamp(),
        'totalDays': record.totalDays,
        'status': 'completed',
      });
    }
    if (active.data()?['active'] == true &&
        (active.data()?['batchNumber'] as num?)?.toInt() == record.batchNumber) {
      transaction.set(activeRef, {
        'active': false,
        'status': 'completed',
        'endedAt': Timestamp.fromDate(record.endDate.toUtc()),
        'totalDays': record.totalDays,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    return true;
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
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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

class _MainGatekeeperState extends State<MainGatekeeper> {
  bool _isLoading = true;

  bool _isPlantingActive = false;
  bool _showContinuePrompt = false;
  bool _dashboardOpen = false;
  DateTime? _plantingStartDate;
  int? _activeBatchNumber;
  List<PlantingRecord> _pastPlantingRuns = [];
  
  String _activeEsp32Ip = "hydrodeck.local";
  StreamSubscription? _bgSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _activePlantingSubscription;

  @override
  void initState() {
    super.initState();
    _loadStoredSessionAndData();
    _listenToBackgroundService();
  }

  @override
  void dispose() {
    _bgSubscription?.cancel();
    _activePlantingSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadStoredSessionAndData() async {
    final localActiveDate = await DatabaseHelper.instance.getActiveSession();
    final localActiveBatch = await DatabaseHelper.instance.getActiveBatchNumber();
    final localRuns = await DatabaseHelper.instance.getPlantingHistory();
    final cloudHistory = await downloadCloudHistory();
    final pastRuns = <PlantingRecord>[...localRuns];
    final knownBatches = pastRuns.map((run) => run.batchNumber).toSet();
    for (final run in cloudHistory.runs) {
      if (knownBatches.add(run.batchNumber)) {
        pastRuns.add(run);
        await DatabaseHelper.instance.insertPlantingRecord(run, cloudSynced: true);
      }
    }
    final localLogs = await DatabaseHelper.instance.getLogs();
    final knownLogKeys = localLogs
        .map((log) => '${log.batchNumber}|${log.timestamp.toIso8601String()}')
        .toSet();
    for (final log in cloudHistory.logs) {
      final key = '${log.batchNumber}|${log.timestamp.toIso8601String()}';
      if (knownLogKeys.add(key)) {
        await DatabaseHelper.instance.insertLogIfMissing(log, cloudSynced: true);
      }
    }

    ActivePlantingSession? activeSession;
    if (cloudHistory.activeStateKnown) {
      activeSession = cloudHistory.activeSession;
      if (activeSession == null) {
        await DatabaseHelper.instance.clearActiveSession();
      } else {
        await DatabaseHelper.instance.saveActiveSession(
          activeSession.startDate,
          activeSession.batchNumber,
        );
      }
    } else if (localActiveDate != null) {
      activeSession = ActivePlantingSession(
        batchNumber: localActiveBatch ??
            (pastRuns.isEmpty ? 1 : pastRuns.last.batchNumber + 1),
        startDate: localActiveDate,
      );
      unawaited(syncLegacyActivePlantingSession(activeSession));
    }

    final savedIp = await DatabaseHelper.instance.getActiveIp();
    if (mounted) {
      setState(() {
        _pastPlantingRuns = pastRuns..sort((a, b) => a.batchNumber.compareTo(b.batchNumber));
        _activeEsp32Ip = savedIp;
        _plantingStartDate = activeSession?.startDate;
        _activeBatchNumber = activeSession?.batchNumber;
        _isPlantingActive = activeSession != null;
        _showContinuePrompt = activeSession != null;
        _isLoading = false;
      });
    }
    final hasPendingRecords = await hasPendingCloudRecords();
    if ((activeSession != null || hasPendingRecords) && _supportsBackgroundService) {
      await initializeBackgroundService();
      FlutterBackgroundService().invoke('setPlantingState', {'active': activeSession != null});
    }
    _subscribeToActivePlanting();
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

  void _subscribeToActivePlanting() {
    try {
      final activeRef = FirebaseFirestore.instance
          .collection('hydrodeckSystems')
          .doc(_sharedHydrodeckSystemId)
          .collection('metadata')
          .doc('activePlanting');
      _activePlantingSubscription = activeRef.snapshots().listen((snapshot) async {
        final data = snapshot.data();
        if (data == null) return;
        final batch = (data['batchNumber'] as num?)?.toInt();
        final start = _parseFirebaseTimestamp(data['startedAt'] ?? data['startDate']);
        if (data['active'] == true && batch != null && start != null) {
          await DatabaseHelper.instance.saveActiveSession(start, batch);
          if (!mounted) return;
          final isNewSession = !_isPlantingActive || _activeBatchNumber != batch;
          setState(() {
            _isPlantingActive = true;
            _plantingStartDate = start;
            _activeBatchNumber = batch;
            if (isNewSession) {
              _showContinuePrompt = true;
              _dashboardOpen = false;
            }
          });
          if (isNewSession && _supportsBackgroundService) {
            await initializeBackgroundService();
            FlutterBackgroundService().invoke('setPlantingState', {'active': true});
          }
          return;
        }

        if (batch != null && start != null) {
          final end = _parseFirebaseTimestamp(data['endedAt']);
          if (end != null) {
            final record = PlantingRecord(
              batchNumber: batch,
              startDate: start,
              endDate: end,
              totalDays: (data['totalDays'] as num?)?.toInt() ?? 1,
            );
            if (!_pastPlantingRuns.any((run) => run.batchNumber == batch)) {
              await DatabaseHelper.instance.insertPlantingRecord(record, cloudSynced: true);
              if (mounted) setState(() => _pastPlantingRuns.add(record));
            }
          }
        }

        if (batch == _activeBatchNumber) {
          await DatabaseHelper.instance.clearActiveSession();
          if (!mounted) return;
          setState(() {
            _isPlantingActive = false;
            _showContinuePrompt = false;
            _dashboardOpen = false;
            _plantingStartDate = null;
            _activeBatchNumber = null;
          });
          if (_supportsBackgroundService) {
            FlutterBackgroundService().invoke('setPlantingState', {'active': false});
          }
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  void _startPlanting() async {
    final now = await getServerNow();
    final localCandidate = _pastPlantingRuns.fold<int>(
          0,
          (maximum, run) => run.batchNumber > maximum ? run.batchNumber : maximum,
        ) +
        1;
    final activeSession = await startOrResumePlanting(now, localCandidate);
    await DatabaseHelper.instance.saveActiveSession(
      activeSession.startDate,
      activeSession.batchNumber,
    );

    if (_supportsBackgroundService) {
      await initializeBackgroundService();
      FlutterBackgroundService().invoke('setPlantingState', {'active': true});
    }

    setState(() {
      _plantingStartDate = activeSession.startDate;
      _activeBatchNumber = activeSession.batchNumber;
      _isPlantingActive = true;
      _showContinuePrompt = false;
      _dashboardOpen = true;
    });
  }

  void _continuePlanting() {
    setState(() {
      _showContinuePrompt = false;
      _dashboardOpen = true;
    });
  }

  void _endPlanting() async {
    if (_plantingStartDate == null) return;

    final now = await getServerNow();
    int totalDays = (now.difference(_plantingStartDate!).inDays + 1).clamp(1, 999999);

    final batchNumber = _activeBatchNumber ??
      await DatabaseHelper.instance.getActiveBatchNumber() ??
        (_pastPlantingRuns.isEmpty ? 1 : _pastPlantingRuns.last.batchNumber + 1);
    final newRecord = PlantingRecord(
      batchNumber: batchNumber,
      startDate: _plantingStartDate!,
      endDate: now,
      totalDays: totalDays,
    );

    await DatabaseHelper.instance.insertPlantingRecord(newRecord);
    await DatabaseHelper.instance.clearActiveSession();
    unawaited(uploadPlantingRecord(newRecord).then((uploaded) async {
      if (uploaded) {
        await DatabaseHelper.instance.markPlantingRecordCloudSynced(newRecord.batchNumber);
      }
    }).catchError((_) {}));
    if (_supportsBackgroundService) {
      FlutterBackgroundService().invoke('setPlantingState', {'active': false});
    }

    setState(() {
      _pastPlantingRuns.add(newRecord);
      _isPlantingActive = false;
      _showContinuePrompt = false;
      _dashboardOpen = false;
      _plantingStartDate = null;
      _activeBatchNumber = null;
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

    if (!_isPlantingActive || (_showContinuePrompt && !_dashboardOpen)) {
      return StartPlantingScreen(
        onStart: _startPlanting,
        onContinue: _continuePlanting,
        activeSession: _isPlantingActive && _plantingStartDate != null && _activeBatchNumber != null
            ? ActivePlantingSession(
                batchNumber: _activeBatchNumber!,
                startDate: _plantingStartDate!,
              )
            : null,
        history: _pastPlantingRuns,
      );
    }
    return HydroponicsDashboard(
      startDate: _plantingStartDate!,
      batchNumber: _activeBatchNumber,
      onEndPlanting: _endPlanting,
      initialIp: _activeEsp32Ip,
    );
  }
}

class StartPlantingScreen extends StatelessWidget {
  final VoidCallback onStart;
  final VoidCallback onContinue;
  final ActivePlantingSession? activeSession;
  final List<PlantingRecord> history;

  const StartPlantingScreen({
    super.key,
    required this.onStart,
    required this.onContinue,
    this.activeSession,
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
                                '${_philippineTime(run.startDate).year}-${_philippineTime(run.startDate).month}-${_philippineTime(run.startDate).day} to ${_philippineTime(run.endDate).year}-${_philippineTime(run.endDate).month}-${_philippineTime(run.endDate).day}',
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
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ProfileScreen()),
              );
            },
          ),
        ],
      ),
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
                    // Replace this Text with Image.asset(...) or any icon you prefer.
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
                  onPressed: activeSession == null ? onStart : onContinue,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2DC867),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    elevation: 2,
                  ),
                  child: Text(
                    activeSession == null ? 'Start Planting' : 'Continue Planting',
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
  final int? batchNumber;
  final VoidCallback onEndPlanting;
  final String initialIp;

  const HydroponicsDashboard({
    super.key,
    required this.startDate,
    this.batchNumber,
    required this.onEndPlanting,
    this.initialIp = "hydrodeck.local",
  });

  @override
  State<HydroponicsDashboard> createState() => _HydroponicsDashboardState();
}

class _HydroponicsDashboardState extends State<HydroponicsDashboard> {
  static const String _esp32Hotspot = 'ESP32-HYDRODECK';
  static const String _esp32HotspotPassword = 'hydrodeck';

  int _currentIndex = 0;

  late String _esp32Ip;
  late TextEditingController _ipController;
  
  String _connectionStatus = "Fetching...";
  bool _firebaseConnected = false;
  
  GrowBedReading _bed1 = GrowBedReading.empty();
  GrowBedReading _bed2 = GrowBedReading.empty();
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
  DateTime? _serverNow;

  StreamSubscription? _telemetrySub;
  StreamSubscription? _snapshotSub;
  StreamSubscription? _firebaseSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _cloudLogsSub;
  StreamSubscription? _firebaseConnectionSub;
  StreamSubscription? _firebaseCommandsSub; // Subscription for command status updates
  Timer? _connectionTimer;
  bool _wifiPromptShown = false;
  bool _isRefreshingConnectivity = false;
  bool _connectivityProbeInProgress = false;
  DateTime? _lastLocalTelemetryAt;
  DateTime? _lastFirebaseTelemetryAt;
  Timer? _thresholdPublishTimer;
  DateTime? _offlineSince;
  List<String> _discoveredHotspots = [];
  final Map<String, bool> _actuatorBusy = {};
  final Map<String, bool> _pendingActuatorStates = {};
  // Track pending command requests to prevent duplicates and enable acknowledgment
  final Map<String, String> _pendingCommandIds = {}; // actuatorName -> commandId
  final Map<String, Timer> _commandTimeouts = {};
  final Set<String> _actuatorsSeenRunning = {};

  List<HistoricalData> _historyLogs = [];
  DateTime? _selectedFilterDate;

  late TextEditingController _wifiSsidController;
  late TextEditingController _wifiPasswordController;
  bool _isHotspotConnecting = false;
  String _hotspotStatus = 'ESP32 hotspot not connected';

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
    unawaited(_subscribeToCloudLogs());
    _subscribeToFirebase();
    _subscribeToFirebaseConnection();
    _subscribeToBackgroundUpdates();
    _subscribeToFirebaseCommands();
    unawaited(_refreshServerTime());

    _offlineSince = DateTime.now();
    unawaited(_refreshConnectivity(showLoading: false));

    _connectionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        unawaited(_refreshConnectivity(showLoading: false));
        setState(_updateConnectionStatus);
        // Only prompt to provision the ESP32 when the user is on the Home screen
        // and the device has been offline for a while. This prevents intrusive
        // popups while navigating other screens.
        if (_connectionStatus != 'Firebase Offline') {
          _offlineSince = null;
          _wifiPromptShown = false;
        } else {
          _offlineSince ??= DateTime.now();
          if (!_wifiPromptShown &&
              _currentIndex == 0 &&
              DateTime.now().difference(_offlineSince!).inSeconds >= 3) {
            _showWifiSetupDialog();
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _telemetrySub?.cancel();
    _snapshotSub?.cancel();
    _firebaseSub?.cancel();
    _cloudLogsSub?.cancel();
    _firebaseConnectionSub?.cancel();
    _firebaseCommandsSub?.cancel();
    _connectionTimer?.cancel();
    _thresholdPublishTimer?.cancel();
    _ipController.dispose();
    _wifiSsidController.dispose();
    _wifiPasswordController.dispose();
    super.dispose();
  }

  void _subscribeToFirebase() {
    if (kIsWeb) return;

    try {
      final ref = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: 'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
      ).ref('hydrodeck');
      _firebaseSub = ref.onValue.listen((event) async {
        final value = event.snapshot.value;
        if (mounted) {
          setState(_updateConnectionStatus);
        }
        if (value is! Map) return;

        final payload = Map<String, dynamic>.from(value);
        final lastSeen = payload['lastSeen'];
        final heartbeatMillis = lastSeen is num
            ? lastSeen.toInt()
            : int.tryParse(lastSeen?.toString() ?? '');
        final heartbeatFresh = heartbeatMillis != null &&
            DateTime.now()
                    .difference(DateTime.fromMillisecondsSinceEpoch(heartbeatMillis))
                    .inSeconds <=
                30;
        final telemetry = HydrodeckTelemetry.fromJson(payload);

        if (!mounted) return;
        setState(() {
          if (heartbeatFresh) {
            _lastFirebaseTelemetryAt = DateTime.now();
          } else {
            _lastFirebaseTelemetryAt = null;
          }
                                        if (payload.containsKey('temp1') || payload.containsKey('ph1') || payload.containsKey('tds1') || payload.containsKey('water1') || payload['bed1'] is Map) {
            _bed1 = telemetry.bed1;
          }
          if (payload.containsKey('temp2') || payload.containsKey('ph2') || payload.containsKey('tds2') || payload.containsKey('water2') || payload['bed2'] is Map) {
            _bed2 = telemetry.bed2;
          }

          final actuators = payload['actuators'] is Map
              ? Map<String, dynamic>.from(payload['actuators'] as Map)
              : payload;
          _updateActuatorFromFirebase('bed1_water', 'waterPump1', actuators);
          _updateActuatorFromFirebase('bed1_ph_up', 'phUp1', actuators);
          _updateActuatorFromFirebase('bed1_ph_down', 'phDown1', actuators);
          _updateActuatorFromFirebase('bed1_nutrient', 'nutrient1', actuators);
          _updateActuatorFromFirebase('bed2_water', 'waterPump2', actuators);
          _updateActuatorFromFirebase('bed2_ph_up', 'phUp2', actuators);
          _updateActuatorFromFirebase('bed2_ph_down', 'phDown2', actuators);
          _updateActuatorFromFirebase('bed2_nutrient', 'nutrient2', actuators);
          final pendingGrowLight = _pendingActuatorStates['grow_light'];
          if (pendingGrowLight == null || pendingGrowLight == telemetry.growLightOn) {
            _controlStates['grow_light'] = telemetry.growLightOn;
            if (pendingGrowLight == telemetry.growLightOn) _pendingActuatorStates.remove('grow_light');
          }
          _updateConnectionStatus();
          if (payload['ip'] != null) {
            _esp32Ip = payload['ip'].toString();
            _ipController.text = _esp32Ip;
          }

        });
      }, onError: (_) {
        if (mounted) setState(_updateConnectionStatus);
      });
    } catch (_) {
      // Firebase is unavailable; telemetry will fall back to manual polling.
    }
  }

  void _subscribeToFirebaseConnection() {
    try {
      final connectionRef = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: 'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
      ).ref('.info/connected');
      _firebaseConnectionSub = connectionRef.onValue.listen((event) {
        if (!mounted) return;
        setState(() {
          _firebaseConnected = event.snapshot.value == true;
          _updateConnectionStatus();
        });
      }, onError: (_) {
        if (!mounted) return;
        setState(() {
          _firebaseConnected = false;
          _updateConnectionStatus();
        });
      });
    } catch (_) {
      _firebaseConnected = false;
    }
  }

  void _subscribeToFirebaseCommands() {
    if (kIsWeb) return;
    try {
      final acknowledgmentsRef = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: 'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
      ).ref('hydrodeck/commandAcks');
      _firebaseCommandsSub = acknowledgmentsRef.onValue.listen((event) {
        if (!mounted) return;
        final value = event.snapshot.value;
        if (value is! Map) return;
        final acknowledgments = Map<String, dynamic>.from(value);
        var changed = false;
        for (final pending in _pendingCommandIds.entries.toList()) {
          final status = acknowledgments[pending.value]?.toString();
          if (status != 'completed' && status != 'failed') continue;
          _pendingCommandIds.remove(pending.key);
          _commandTimeouts.remove(pending.value)?.cancel();
          final busyKey = _getActuatorBusyKey(pending.key);
          if (busyKey != null) {
            _actuatorBusy[busyKey] = false;
            _pendingActuatorStates.remove(busyKey);
          }
          changed = true;
        }
        if (changed && mounted) setState(() {});
      });
    } catch (_) {
      // Firebase commands subscription failed - commands will rely on telemetry feedback
    }
  }

  String? _getActuatorBusyKey(String actuatorName) {
    return _actuatorControlKeys[actuatorName];
  }

  bool _otherWaterPumpIsRunning(String actuatorName) {
    final otherActuator = switch (actuatorName) {
      'waterPump1' => 'waterPump2',
      'waterPump2' => 'waterPump1',
      _ => null,
    };
    if (otherActuator == null) return false;
    final otherKey = _actuatorControlKeys[otherActuator]!;
    return _actuatorBusy[otherKey] == true ||
        _pendingCommandIds.containsKey(otherActuator);
  }

  void _updateActuatorStates(Map<String, bool> states) {
    for (final entry in states.entries) {
      final key = _actuatorControlKeys[entry.key];
      if (key != null) {
        _updateActuatorFromFirebase(key, entry.key, {entry.key: entry.value});
      }
    }
  }

  void _updateActuatorFromFirebase(String key, String actuatorName, Map<String, dynamic> actuators) {
    if (!actuators.containsKey(actuatorName)) return;
    final value = HydrodeckTelemetry._readBoolLike(actuators, [actuatorName]);
    final pendingId = _pendingCommandIds[actuatorName];
    if (pendingId != null) {
      if (value) {
        _actuatorsSeenRunning.add(key);
      } else if (_actuatorsSeenRunning.remove(key)) {
        _clearPendingCommand(actuatorName, pendingId);
      } else {
        _actuatorBusy[key] = true;
      }
      return;
    }

    _controlStates[key] = value;
    _actuatorBusy[key] = value;
    if (value) {
      _actuatorsSeenRunning.add(key);
    } else {
      _actuatorsSeenRunning.remove(key);
    }
  }

  Future<void> _refreshServerTime() async {
    DateTime now;
    try {
      now = await getServerNow();
    } catch (e) {
      // Failed to get server time, do not update _serverNow
      return;
    }
    if (mounted) {
      setState(() => _serverNow = now);
    }
  }

  Future<void> _refreshConnectivity({bool showLoading = true}) async {
    if (_connectivityProbeInProgress) return;
    _connectivityProbeInProgress = true;
    if (showLoading && mounted) setState(() => _isRefreshingConnectivity = true);
    var localConnected = false;
    try {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(true);
      } catch (_) {}
      final targets = <String>{_esp32Ip.trim(), '192.168.4.1', 'hydrodeck.local'}
        ..remove('');
      Future<MapEntry<String, HydrodeckTelemetry>?> probe(String target) async {
        try {
          final response = await http.get(
            Uri.parse('http://$target/status'),
            headers: {'Connection': 'close'},
          ).timeout(const Duration(milliseconds: 900));
          if (response.statusCode != 200) return null;
          final decoded = jsonDecode(response.body);
          if (decoded is! Map) return null;
          final telemetry = HydrodeckTelemetry.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          return MapEntry(target, telemetry);
        } catch (_) {
          return null;
        }
      }

      final localResults = await Future.wait(targets.map(probe));
      for (final result in localResults.whereType<MapEntry<String, HydrodeckTelemetry>>()) {
        if (!mounted) return;
        setState(() {
          _bed1 = result.value.bed1;
          _bed2 = result.value.bed2;
          _controlStates['grow_light'] = result.value.growLightOn;
          _updateActuatorStates(result.value.actuatorStates);
          _esp32Ip = result.key;
          _ipController.text = result.key;
          _lastLocalTelemetryAt = DateTime.now();
        });
        localConnected = true;
        if (_currentIndex == 0) break;
      }

      if (!localConnected) {
        try {
          await WiFiForIoTPlugin.forceWifiUsage(false);
        } catch (_) {}
        var firebaseReachable = false;
        var freshDeviceHeartbeat = false;
        try {
          final database = FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL: 'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
          );
          final connection = await database.ref('.info/connected')
              .get()
              .timeout(const Duration(seconds: 2));
          firebaseReachable = connection.value == true;
          final snapshot = await database.ref('hydrodeck/lastSeen')
              .get()
              .timeout(const Duration(seconds: 2));
          final heartbeatMillis = snapshot.value is num
              ? (snapshot.value as num).toInt()
              : int.tryParse(snapshot.value?.toString() ?? '');
          freshDeviceHeartbeat = heartbeatMillis != null &&
              DateTime.now()
                      .difference(DateTime.fromMillisecondsSinceEpoch(heartbeatMillis))
                      .inSeconds <=
                  30;
          if (freshDeviceHeartbeat) {
            _lastFirebaseTelemetryAt = DateTime.now();
          }
        } catch (_) {}
        if (mounted) {
          setState(() {
            _firebaseConnected = firebaseReachable;
            _lastLocalTelemetryAt = null;
            if (!freshDeviceHeartbeat) _lastFirebaseTelemetryAt = null;
          });
        }
      }
    } finally {
      _connectivityProbeInProgress = false;
      if (mounted) {
        setState(() {
          if (showLoading) _isRefreshingConnectivity = false;
          _updateConnectionStatus();
        });
      }
    }
  }

  void _updateConnectionStatus() {
    final localTelemetryFresh = _lastLocalTelemetryAt != null &&
        DateTime.now().difference(_lastLocalTelemetryAt!).inSeconds <= 10;

    if (localTelemetryFresh) {
      _connectionStatus = 'Connected locally';
    } else if (_hasFreshFirebaseTelemetry) {
      _connectionStatus = 'Connected';
    } else if (_firebaseConnected) {
      _connectionStatus = 'ESP32 Offline';
    } else {
      _connectionStatus = 'Firebase Offline';
    }
  }

  bool get _hasFreshFirebaseTelemetry => _lastFirebaseTelemetryAt != null &&
      DateTime.now().difference(_lastFirebaseTelemetryAt!).inSeconds <= 15;

  
  Future<void> _loadStoredLogsAndSettings() async {
    final activeBatchNumber = widget.batchNumber ??
        await DatabaseHelper.instance.getActiveBatchNumber();
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

  Future<void> _subscribeToCloudLogs() async {
    final batchNumber = widget.batchNumber ??
        await DatabaseHelper.instance.getActiveBatchNumber();
    if (batchNumber == null || FirebaseAuth.instance.currentUser == null) return;

    try {
      _cloudLogsSub = FirebaseFirestore.instance
          .collection('hydrodeckSystems')
          .doc(_sharedHydrodeckSystemId)
          .collection('minuteLogs')
          .where('batchNumber', isEqualTo: batchNumber)
          .snapshots()
          .listen((snapshot) async {
        final incoming = <HistoricalData>[];
        for (final document in snapshot.docs) {
          final map = document.data();
          final timestamp = _parseFirebaseTimestamp(map['sampleTime'] ?? map['timestamp']);
          if (timestamp == null) continue;
          incoming.add(HistoricalData(
            timestamp: timestamp,
            pH: (map['pH'] as num?)?.toDouble() ?? 0,
            temperature: map['temperature']?.toString() ?? '',
            waterLevel: map['waterLevel']?.toString() ?? 'Needs water',
            tds: (map['tds'] as num?)?.toDouble() ?? 0,
            batchNumber: (map['batchNumber'] as num?)?.toInt() ?? batchNumber,
            bed1: _decodeBedData(map['bed1']),
            bed2: _decodeBedData(map['bed2']),
          ));
        }
        for (final log in incoming) {
          await DatabaseHelper.instance.insertLogIfMissing(log, cloudSynced: true);
        }
        if (!mounted || incoming.isEmpty) return;
        setState(() {
          final merged = <String, HistoricalData>{
            for (final log in _historyLogs)
              '${log.batchNumber}|${log.timestamp.toUtc().millisecondsSinceEpoch}': log,
          };
          for (final log in incoming) {
            merged['${log.batchNumber}|${log.timestamp.toUtc().millisecondsSinceEpoch}'] = log;
          }
          _historyLogs = merged.values.toList()
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        });
      }, onError: (_) {});
    } catch (_) {}
  }

  
  void _subscribeToBackgroundUpdates() {
    if (kIsWeb || !_supportsBackgroundService) return;

    try {
      _telemetrySub = FlutterBackgroundService().on('telemetryUpdate').listen((event) {
        if (event != null && mounted) {
          setState(() {
                        if (event['source'] == 'local') {
              _lastLocalTelemetryAt = DateTime.now();
            } else if (event['source'] == 'offline') {
              _lastLocalTelemetryAt = null;
            } else if (event['source'] == 'firebase') {
              if (event['isConnected'] == true) {
                _lastFirebaseTelemetryAt = DateTime.now();
              }
                          _firebaseConnected = true;
            }
            _updateConnectionStatus();
            if (event['bed1'] != null) {
              _bed1 = GrowBedReading.fromMap(Map<String, dynamic>.from(event['bed1'] as Map));
            }
            if (event['bed2'] != null) {
              _bed2 = GrowBedReading.fromMap(Map<String, dynamic>.from(event['bed2'] as Map));
            }
            if (event['growLight'] != null) {
                _controlStates['grow_light'] = event['growLight'] is bool
                  ? event['growLight'] as bool
                  : (event['growLight'].toString() == '1' || event['growLight'].toString().toLowerCase() == 'true');
            }
            if (event['actuators'] is Map) {
              final actuatorMap = Map<String, dynamic>.from(event['actuators'] as Map);
              _updateActuatorFromFirebase('bed1_water', 'waterPump1', actuatorMap);
              _updateActuatorFromFirebase('bed1_ph_up', 'phUp1', actuatorMap);
              _updateActuatorFromFirebase('bed1_ph_down', 'phDown1', actuatorMap);
              _updateActuatorFromFirebase('bed1_nutrient', 'nutrient1', actuatorMap);
              _updateActuatorFromFirebase('bed2_water', 'waterPump2', actuatorMap);
              _updateActuatorFromFirebase('bed2_ph_up', 'phUp2', actuatorMap);
              _updateActuatorFromFirebase('bed2_ph_down', 'phDown2', actuatorMap);
              _updateActuatorFromFirebase('bed2_nutrient', 'nutrient2', actuatorMap);
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
            bed1: _decodeBedData(event['bed1']),
            bed2: _decodeBedData(event['bed2']),
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
    final start = _philippineTime(widget.startDate);
    final current = _philippineTime(timestamp);
    final startDay = DateTime(start.year, start.month, start.day);
    final currentDay = DateTime(current.year, current.month, current.day);
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
    final philippinesTime = _philippineTime(dt);
    String month = months[philippinesTime.month - 1];
    int hour24 = philippinesTime.hour;
    String amPm = hour24 >= 12 ? "PM" : "AM";
    int hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    String minutes = dt.minute.toString().padLeft(2, '0');
    
    return "$month ${philippinesTime.day}, ${philippinesTime.year} $hour12:$minutes $amPm";
  }

  String _getDateCategoryHeader(DateTime dt) {
    int dayNum = _getElapsedPlantingDay(dt);
    if (dayNum >= 1) {
      return "Day $dayNum";
    }
    return "Pre-cycle Preparation";
  }

  void _trackPendingCommand(String key, String actuatorName, String commandId) {
    _pendingCommandIds[actuatorName] = commandId;
    _pendingActuatorStates[key] = true;
    _actuatorBusy[key] = true;
    _actuatorsSeenRunning.remove(key);
    _commandTimeouts[commandId]?.cancel();
    final timeout = actuatorName.startsWith('waterPump')
        ? const Duration(minutes: 3)
        : const Duration(seconds: 20);
    _commandTimeouts[commandId] = Timer(timeout, () {
      if (_pendingCommandIds[actuatorName] != commandId) return;
      _pendingCommandIds.remove(actuatorName);
      _commandTimeouts.remove(commandId);
      _pendingActuatorStates.remove(key);
      _actuatorBusy[key] = false;
      if (mounted) setState(() {});
    });
  }

  void _clearPendingCommand(String actuatorName, String commandId) {
    if (_pendingCommandIds[actuatorName] != commandId) return;
    _pendingCommandIds.remove(actuatorName);
    _commandTimeouts.remove(commandId)?.cancel();
    final key = _getActuatorBusyKey(actuatorName);
    if (key != null) {
      _pendingActuatorStates.remove(key);
      _actuatorBusy[key] = false;
    }
  }

  Future<void> _toggleActuator(String key, String actuatorName) async {
    if (_pendingCommandIds.containsKey(actuatorName) || _actuatorBusy[key] == true) return;
    if (_otherWaterPumpIsRunning(actuatorName)) return;
    if ((key == 'bed1_ph_down' && _bed1.ph < _minPhThreshold) ||
        (key == 'bed1_ph_up' && _bed1.ph > _maxPhThreshold) ||
        (key == 'bed2_ph_down' && _bed2.ph < _minPhThreshold) ||
        (key == 'bed2_ph_up' && _bed2.ph > _maxPhThreshold)) {
      return;
    }

    final savedTarget = _esp32Ip.trim();
    final targets = <String>{
      if (savedTarget.isNotEmpty) savedTarget,
      '192.168.4.1',
      'hydrodeck.local',
    };
    final isGrowLight = actuatorName == 'growLight';
    final nextGrowLight = !(_controlStates['grow_light'] ?? false);
    final database = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: 'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
    );
    final commandSlot = database.ref('hydrodeck/commands/$actuatorName');
    final commandId = commandSlot.push().key ??
        'cmd_${DateTime.now().microsecondsSinceEpoch}_${actuatorName.hashCode.abs()}';

    _trackPendingCommand(key, actuatorName, commandId);
    if (isGrowLight) _pendingActuatorStates[key] = nextGrowLight;
    if (mounted) setState(() {});

    var sent = false;
    try {
      final payload = isGrowLight
          ? '$commandId|${nextGrowLight ? 1 : 0}'
          : commandId;
      await commandSlot.set(payload).timeout(const Duration(seconds: 3));
      sent = true;
    } catch (_) {
      // Retry over local HTTP when Firebase cannot accept the command.
    }

    if (!sent) {
      for (final target in targets) {
        try {
          final parameters = <String, String>{
            'actuator': actuatorName,
            'state': isGrowLight ? (nextGrowLight ? '1' : '0') : '1',
            if (!isGrowLight) 'requestId': commandId,
          };
          final response = await http.get(
            Uri.http(target, '/control', parameters),
            headers: {'Connection': 'close'},
          ).timeout(const Duration(seconds: 2));
          if (response.statusCode == 200) {
            if (isGrowLight) {
              _controlStates['grow_light'] = nextGrowLight;
              _clearPendingCommand(actuatorName, commandId);
            }
            if (target != savedTarget && _supportsBackgroundService) {
              FlutterBackgroundService().invoke('updateIp', {'ip': target});
            }
            sent = true;
            break;
          }
        } catch (_) {}
      }
    }

    if (!sent) {
      // Both Firebase and HTTP failed
      _clearPendingCommand(actuatorName, commandId);
      if (mounted) setState(() {});
      return;
    }
  }

  Future<void> _connectToEsp32Hotspot() async {
    if (_isHotspotConnecting) return;
    setState(() {
      _isHotspotConnecting = true;
      _hotspotStatus = 'Connecting to $_esp32Hotspot...';
    });
    try {
      await WiFiForIoTPlugin.connect(
        _esp32Hotspot,
        password: _esp32HotspotPassword,
        security: NetworkSecurity.WPA,
        joinOnce: true,
      );
      await WiFiForIoTPlugin.forceWifiUsage(true);
      final response = await http.get(
        Uri.parse('http://192.168.4.1/status'),
        headers: {'Connection': 'close'},
      ).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw Exception('ESP32 did not respond on its hotspot.');
      }
      final telemetry = HydrodeckTelemetry.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map),
      );
      await DatabaseHelper.instance.saveActiveIp('192.168.4.1');
      if (!mounted) return;
      setState(() {
        _esp32Ip = '192.168.4.1';
        _ipController.text = _esp32Ip;
        _lastLocalTelemetryAt = DateTime.now();
        _bed1 = telemetry.bed1;
        _bed2 = telemetry.bed2;
        _hotspotStatus = 'Connected to ESP32 hotspot for local control.';
        _updateConnectionStatus();
      });
      if (_supportsBackgroundService) {
        FlutterBackgroundService().invoke('updateIp', {'ip': '192.168.4.1'});
      }
    } catch (error) {
      if (mounted) setState(() => _hotspotStatus = 'Hotspot connection failed: $error');
    } finally {
      if (mounted) setState(() => _isHotspotConnecting = false);
    }
  }

  void _showWifiSetupDialog() {
    if (_wifiPromptShown || !mounted || _currentIndex != 0) return;
    _wifiPromptShown = true;
    showDialog(
      context: context,
      builder: (context) {
        bool scanning = false;
        String? selectedHotspot;
        String? scanMessage;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Connect the ESP32 to Wi-Fi'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Find the ESP32 hotspot, then enter the Wi-Fi network the device should join.'),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: scanning ? null : () async {
                      setDialogState(() { scanning = true; scanMessage = null; });
                      try {
                        final canScan = await WiFiScan.instance.canStartScan(askPermissions: true);
                        if (canScan != CanStartScan.yes) {
                          throw Exception('Wi-Fi scan permission or service is unavailable.');
                        }
                        final canReadResults = await WiFiScan.instance.canGetScannedResults(askPermissions: true);
                        if (canReadResults != CanGetScannedResults.yes) {
                          throw Exception('Wi-Fi scan results are unavailable.');
                        }
                        final resultsFuture = WiFiScan.instance.onScannedResultsAvailable
                            .first
                            .timeout(const Duration(seconds: 12));
                        final started = await WiFiScan.instance.startScan();
                        if (!started) throw Exception('The Wi-Fi scan did not start.');
                        final networks = await resultsFuture;
                        final matches = networks
                            .map((network) => network.ssid)
                            .where((ssid) => ssid.contains(_esp32Hotspot))
                            .toSet()
                            .toList();
                        if (mounted) setState(() => _discoveredHotspots = matches);
                        if (matches.contains(_esp32Hotspot)) selectedHotspot = _esp32Hotspot;
                        setDialogState(() {
                          scanning = false;
                          scanMessage = matches.isEmpty ? 'ESP32 hotspot not found. Power it on and scan again.' : null;
                        });
                      } catch (_) {
                        setDialogState(() {
                          scanning = false;
                          scanMessage = 'Wi-Fi scan unavailable. Enable Wi-Fi/location access, or connect to $_esp32Hotspot manually.';
                        });
                      }
                    },
                    icon: const Icon(Icons.wifi_find),
                    label: Text(scanning ? 'Searching...' : 'Search for ESP32 hotspot'),
                  ),
                  if (_discoveredHotspots.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: selectedHotspot,
                      decoration: const InputDecoration(labelText: 'ESP32 hotspot'),
                      items: _discoveredHotspots.map((ssid) => DropdownMenuItem(value: ssid, child: Text(ssid))).toList(),
                      onChanged: (value) => setDialogState(() => selectedHotspot = value),
                    ),
                  if (scanMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(scanMessage!, style: const TextStyle(color: Colors.orange, fontSize: 12)),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _wifiSsidController,
                    decoration: const InputDecoration(labelText: 'New Wi-Fi SSID', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  _PasswordVisibilityField(controller: _wifiPasswordController, label: 'New Wi-Fi password', icon: Icons.lock_outline),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _connectAndProvisionWifi(hotspotSsid: selectedHotspot ?? _esp32Hotspot);
                },
                child: const Text('Connect'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _connectAndProvisionWifi({String hotspotSsid = _esp32Hotspot}) async {
    final ssid = _wifiSsidController.text.trim();
    final password = _wifiPasswordController.text;
    if (ssid.isEmpty || password.isEmpty) {
      setState(() => _hotspotStatus = 'Enter both Wi-Fi fields first');
      return;
    }

    setState(() {
      _isHotspotConnecting = true;
      _hotspotStatus = 'Connecting to $hotspotSsid...';
    });
    try {
      await WiFiForIoTPlugin.connect(hotspotSsid, password: _esp32HotspotPassword, security: NetworkSecurity.WPA, joinOnce: true);
      await WiFiForIoTPlugin.forceWifiUsage(true);
      final response = await http.get(Uri.parse('http://192.168.4.1/provision?ssid=${Uri.encodeQueryComponent(ssid)}&password=${Uri.encodeQueryComponent(password)}')).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) throw Exception(response.body);
      if (mounted) {
        setState(() => _hotspotStatus = 'Wi-Fi sent. Returning your phone to its normal network...');
      }
      await WiFiForIoTPlugin.forceWifiUsage(false);
      await WiFiForIoTPlugin.disconnect();
      try {
        await WiFiForIoTPlugin.removeWifiNetwork(hotspotSsid);
      } catch (_) {
        // Android/iOS may restrict programmatic removal; disconnect still succeeds.
      }
      if (mounted) {
        setState(() => _hotspotStatus = 'ESP32 is joining $ssid. Reconnect to your home Wi-Fi on this phone.');
      }
    } catch (error) {
      setState(() => _hotspotStatus = 'Hotspot setup failed: $error');
    } finally {
      if (mounted) setState(() => _isHotspotConnecting = false);
    }
  }

  Future<void> _publishPhThresholds() async {
    try {
      final settingsRef = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: 'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
      ).ref('hydrodeck/settings');
      await Future.wait([
        settingsRef.child('minPh').set(_minPhThreshold),
        settingsRef.child('maxPh').set(_maxPhThreshold),
      ]);
    } catch (_) {}

    for (final target in <String>{_esp32Ip.trim(), '192.168.4.1', 'hydrodeck.local'}..remove('')) {
      try {
        await http.get(Uri.parse(
          'http://$target/settings?minPh=${_minPhThreshold.toStringAsFixed(2)}&maxPh=${_maxPhThreshold.toStringAsFixed(2)}',
        )).timeout(const Duration(seconds: 2));
        return;
      } catch (_) {}
    }
  }

  void _schedulePhThresholdPublish() {
    _thresholdPublishTimer?.cancel();
    _thresholdPublishTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_publishPhThresholds()),
    );
  }

  void _showConnectionHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect Hydrodeck'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('1. Power on the ESP32 and wait for its setup hotspot.'),
              SizedBox(height: 10),
              Text('2. If it is not on your home Wi-Fi, tap the Wi-Fi setup prompt and search for ESP32-HYDRODECK.'),
              SizedBox(height: 10),
              Text('3. Connect to the hotspot using its configured password, then enter your home Wi-Fi name and password.'),
              SizedBox(height: 10),
              Text('4. The ESP32 stays available on its hotspot while it joins home Wi-Fi. Reconnect this phone to the same home Wi-Fi for direct local access.'),
              SizedBox(height: 10),
              Text('5. Tap refresh. “Connected locally” means this phone can reach the ESP32; “System online” means Firebase and the ESP32 heartbeat are current.'),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
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
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: _currentIndex == 3 ? [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ProfileScreen()),
              );
            },
          ),
        ] : const [],
      ),
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

  // Home screen
  Widget _buildHomeScreen(String waterLabel) {
    final isOnline = _connectionStatus.startsWith('Connected') || _connectionStatus == 'System Online';
    final statusColor = isOnline ? Colors.green : Colors.orange;
    final statusText = _connectionStatus == 'Connected' ? 'System Online' : _connectionStatus;
    final isBed1Warning = _bed1.ph < _minPhThreshold || _bed1.ph > _maxPhThreshold;
    final isBed2Warning = _bed2.ph < _minPhThreshold || _bed2.ph > _maxPhThreshold;
    final hasPhWarning = isBed1Warning || isBed2Warning;
    final currentDayCount = _getElapsedPlantingDay(_serverNow ?? DateTime.now());

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Home', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Connection guide',
                    onPressed: _showConnectionHelp,
                    icon: const Icon(Icons.help_outline),
                  ),
                  IconButton(
                    tooltip: 'Refresh connection status',
                    onPressed: _isRefreshingConnectivity ? null : () => _refreshConnectivity(),
                    icon: _isRefreshingConnectivity
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
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

          hasPhWarning
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
                        children: [
                          Text(
                            isBed1Warning && isBed2Warning
                                ? 'GROW BED 1 AND 2 pH WARNING'
                                : isBed1Warning
                                    ? 'GROW BED 1 pH WARNING'
                                    : 'GROW BED 2 pH WARNING',
                            style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1),
                          ),
                          Icon(Icons.warning_amber_rounded, color: Colors.white, size: 26),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text('pH ALERT', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(
                        isBed1Warning && isBed2Warning
                          ? 'Grow beds 1 and 2 are outside the target range at ${_bed1.ph.toStringAsFixed(2)} and ${_bed2.ph.toStringAsFixed(2)} pH. Target range is ${_minPhThreshold.toStringAsFixed(1)} - ${_maxPhThreshold.toStringAsFixed(1)} pH.'
                          : isBed1Warning
                            ? 'Grow bed 1 is outside the target range at ${_bed1.ph.toStringAsFixed(2)} pH. Target range is ${_minPhThreshold.toStringAsFixed(1)} - ${_maxPhThreshold.toStringAsFixed(1)} pH.'
                            : 'Grow bed 2 is outside the target range at ${_bed2.ph.toStringAsFixed(2)} pH. Target range is ${_minPhThreshold.toStringAsFixed(1)} - ${_maxPhThreshold.toStringAsFixed(1)} pH.',
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

  // TDS, pH, temperature, and water-level metrics
  Widget _buildGrowBedMetrics(String title, GrowBedReading data) {
    final isPhOptimal = data.ph >= _minPhThreshold && data.ph <= _maxPhThreshold;
    final isTdsOptimal = data.tds < 900;
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

  // Old simple toggle helper removed; controls now use the redesigned layout.

  // Control screen
  Widget _buildControlScreen() {
    Widget sectionTitle(String title) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 8),
          child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        );

    Widget phRow(int bedIndex, GrowBedReading bed) {
      final isCritical = bed.ph < _minPhThreshold || bed.ph > _maxPhThreshold;
      final minusKey = 'bed${bedIndex}_ph_down';
      final plusKey = 'bed${bedIndex}_ph_up';
      final minusName = bedIndex == 1 ? 'phDown1' : 'phDown2';
      final plusName = bedIndex == 1 ? 'phUp1' : 'phUp2';
      final minusNeeded = bed.ph > _maxPhThreshold;
      final plusNeeded = bed.ph < _minPhThreshold;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: isCritical ? Colors.red.shade100 : Colors.white,
        child: Row(children: [
          Expanded(flex: 2, child: Text('Grow bed $bedIndex', style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(bed.ph.toStringAsFixed(2), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          const SizedBox(width: 8),
          SizedBox(width: 54, height: 52, child: ElevatedButton(
            onPressed: _actuatorBusy[minusKey] == true || _actuatorBusy[plusKey] == true || bed.ph < _minPhThreshold ? null : () => _toggleActuator(minusKey, minusName),
            style: ElevatedButton.styleFrom(backgroundColor: minusNeeded ? Colors.red : Colors.grey.shade200, foregroundColor: minusNeeded ? Colors.white : Colors.black87, padding: EdgeInsets.zero),
            child: const Text('-', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          )),
          const SizedBox(width: 8),
          SizedBox(width: 54, height: 52, child: ElevatedButton(
            onPressed: _actuatorBusy[plusKey] == true || _actuatorBusy[minusKey] == true || bed.ph > _maxPhThreshold ? null : () => _toggleActuator(plusKey, plusName),
            style: ElevatedButton.styleFrom(backgroundColor: plusNeeded ? Colors.green : Colors.grey.shade200, foregroundColor: plusNeeded ? Colors.white : Colors.black87, padding: EdgeInsets.zero),
            child: const Text('+', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          )),
        ]),
      );
    }

    Widget pumpRow(int bedIndex, {required bool nutrient}) {
      final key = nutrient ? 'bed${bedIndex}_nutrient' : 'bed${bedIndex}_water';
      final actuator = nutrient
          ? (bedIndex == 1 ? 'nutrient1' : 'nutrient2')
          : (bedIndex == 1 ? 'waterPump1' : 'waterPump2');
      final needsWater = bedIndex == 1 ? !_bed1.waterFull : !_bed2.waterFull;
      final otherWaterPumpRunning = !nutrient && _otherWaterPumpIsRunning(actuator);
      return Container(
        color: !nutrient && needsWater ? Colors.yellow.shade100 : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(children: [
          Expanded(child: Text('Grow bed $bedIndex', style: const TextStyle(fontWeight: FontWeight.w600))),
          SizedBox(width: 112, height: 48, child: ElevatedButton(
            onPressed: _actuatorBusy[key] == true || otherWaterPumpRunning
              ? null
              : () => _toggleActuator(key, actuator),
            style: ElevatedButton.styleFrom(
              backgroundColor: !nutrient && needsWater ? Colors.amber.shade300 : Colors.grey.shade200,
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(nutrient ? 'ADD' : 'PUMP', style: const TextStyle(fontWeight: FontWeight.bold)),
          )),
        ]),
      );
    }

    Widget separatedRows(List<Widget> rows) => Container(
          decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.grey.shade200), borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            for (var index = 0; index < rows.length; index++) ...[
              if (index > 0) Divider(height: 1, color: Colors.grey.shade200),
              rows[index],
            ],
          ]),
        );

    final growLightOn = _controlStates['grow_light'] ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Hardware Controls', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        sectionTitle('PH LEVEL'),
        separatedRows([phRow(1, _bed1), phRow(2, _bed2)]),
        sectionTitle('WATER PUMP'),
        separatedRows([pumpRow(1, nutrient: false), pumpRow(2, nutrient: false)]),
        sectionTitle('NUTRIENT SOLUTION'),
        separatedRows([pumpRow(1, nutrient: true), pumpRow(2, nutrient: true)]),
        sectionTitle('GROW LIGHT'),
        SizedBox(width: double.infinity, height: 52, child: ElevatedButton(
          key: const ValueKey('grow-light-button'),
          onPressed: _actuatorBusy['grow_light'] == true ? null : () => _toggleActuator('grow_light', 'growLight'),
          style: ElevatedButton.styleFrom(
            backgroundColor: growLightOn ? const Color(0xFF2DC867) : Colors.grey.shade200,
            foregroundColor: growLightOn ? Colors.white : Colors.black87,
          ),
          child: Text(growLightOn ? 'ON' : 'OFF', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        )),
      ]),
    );
  }

  // Data screen
  Widget _buildDataScreen() {
    List<HistoricalData> filteredLogs = _historyLogs.where((log) {
      if (_selectedFilterDate == null) return true;
        final logDate = _philippineTime(log.timestamp);
        return logDate.year == _selectedFilterDate!.year &&
          logDate.month == _selectedFilterDate!.month &&
          logDate.day == _selectedFilterDate!.day;
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
            'Saved snapshots (uploaded every 5 minutes):',
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

  // Settings screen
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

          const Text('ESP32 Hotspot Setup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87)),
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
                _PasswordVisibilityField(controller: _wifiPasswordController, label: 'Wi-Fi Password', icon: Icons.lock_outline),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isHotspotConnecting ? null : _connectAndProvisionWifi,
                    icon: const Icon(Icons.wifi_find),
                    label: Text(_isHotspotConnecting ? 'Connecting...' : 'Send Wi-Fi to ESP32'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2DC867),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isHotspotConnecting ? null : _connectToEsp32Hotspot,
                    icon: const Icon(Icons.wifi),
                    label: Text(_isHotspotConnecting ? 'Connecting...' : 'Connect to ESP32 Hotspot'),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_hotspotStatus, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
                    _schedulePhThresholdPublish();
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
                    _schedulePhThresholdPublish();
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
    final bed1 = data.bed1 ?? GrowBedReading.empty();
    final bed2 = data.bed2 ?? GrowBedReading.empty();
    final bed1WaterFull = bed1.waterFull;
    final bed2WaterFull = bed2.waterFull;
    final bed1PhOptimal = bed1.ph >= minPh && bed1.ph <= maxPh;
    final bed2PhOptimal = bed2.ph >= minPh && bed2.ph <= maxPh;

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
            _buildStaticGrid(bed1, bed1WaterFull, bed1PhOptimal),
            
            const SizedBox(height: 24),
            const Text('Grow Bed 2 (Historical Metrics)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _buildStaticGrid(bed2, bed2WaterFull, bed2PhOptimal),
          ],
        ),
      ),
    );
  }

  Widget _buildStaticGrid(GrowBedReading bed, bool isWaterFull, bool isPhOptimal) {
    final isTdsOptimal = bed.tds < 900;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildStaticCard(
                'ACIDITY (PH)', 
                '${bed.ph.toStringAsFixed(2)} pH', 
                isPhOptimal ? 'Normal' : 'Unstable',
                bgOverride: isPhOptimal ? const Color(0xFFE8F7ED) : const Color(0xFFFFF3E0),
                textOverride: isPhOptimal ? Colors.green : Colors.orange,
              )
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildStaticCard(
                'TDS', 
                '${bed.tds.toStringAsFixed(0)} PPM', 
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
            Expanded(child: _buildStaticCard('WATER TEMP', '${bed.temperature.toStringAsFixed(1)}°C', 'Log Data')),
            const SizedBox(width: 16),
            Expanded(
              child: _buildStaticCard(
                'GROW BED WATER LEVEL',
                isWaterFull ? 'Water Full' : 'Needs Water',
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