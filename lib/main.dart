export 'policy_documents.dart';
export 'support_request.dart';

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
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'package:flutter/services.dart';
import 'history_interval.dart';
import 'login_validation.dart';
import 'command_ack_policy.dart';
import 'wifi_provisioning_policy.dart';
import 'hotspot_attempt_policy.dart';
import 'device_presence_policy.dart';
import 'critical_ph_policy.dart';
import 'planting_navigation.dart';
import 'policy_documents.dart';
import 'support_request.dart';
import 'weather_service.dart';

bool get _supportsBackgroundService =>
    !kIsWeb &&
    !const bool.fromEnvironment('FLUTTER_TEST') &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

int? _cachedServerTimeOffsetMs;
DateTime? _serverClockAnchorUtc;
Stopwatch? _serverClockStopwatch;
const int _deviceHeartbeatGraceSeconds = 60;
const double _minimumPhSetting = 4.0;
const double _maximumPhSetting = 7.0;
const double _minimumMaxPhSetting = 6.0;
const double _maximumMaxPhSetting = 9.0;

bool isValidPhThresholds(double minimum, double maximum) =>
    minimum.isFinite &&
    maximum.isFinite &&
    minimum >= _minimumPhSetting &&
    minimum <= _maximumPhSetting &&
    maximum >= _minimumMaxPhSetting &&
    maximum <= _maximumMaxPhSetting &&
    minimum < maximum;

bool isValidTemperatureReading(double temperature) =>
    temperature.isFinite && temperature > -50.0 && temperature <= 125.0;

String temperatureStatusLabel({
  required double temperature,
  required bool valid,
  required bool fresh,
}) {
  if (!valid || !fresh || !isValidTemperatureReading(temperature)) {
    return 'Unavailable';
  }
  return temperature > 28.0 ? 'Too hot' : 'Normal';
}

DateTime _philippineTime(DateTime timestamp) => manilaDateTime(timestamp);

FirebaseDatabase hydrodeckDatabase() => FirebaseDatabase.instanceFor(
  app: Firebase.app(),
  databaseURL:
      'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
);

const Duration commandAckTimeout = Duration(seconds: 20);

Future<DateTime> getServerNow() async {
  try {
    final snapshot = await FirebaseDatabase.instance
        .ref('.info/serverTimeOffset')
        .get()
        .timeout(const Duration(seconds: 2));
    if (snapshot.value is num) {
      _cachedServerTimeOffsetMs = (snapshot.value as num).round();
      _serverClockAnchorUtc = DateTime.now().toUtc().add(
        Duration(milliseconds: _cachedServerTimeOffsetMs!),
      );
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

  @visibleForTesting
  static void setDatabaseForTesting(Database? database) {
    _database = database;
  }

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
      version: 11,
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
          await db.execute(
            'ALTER TABLE historical_logs ADD COLUMN batchNumber INTEGER',
          );
          await db.execute(
            'ALTER TABLE active_session ADD COLUMN batchNumber INTEGER NOT NULL DEFAULT 1',
          );
        }
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE historical_logs ADD COLUMN bed1 TEXT');
          await db.execute('ALTER TABLE historical_logs ADD COLUMN bed2 TEXT');
        }
        if (oldVersion < 7) {
          await db.execute(
            'ALTER TABLE historical_logs ADD COLUMN cloudSynced INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 8) {
          await db.execute(
            'ALTER TABLE planting_history ADD COLUMN cloudSynced INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 9) {
          await _migrateScheduledHistoryIdentities(db);
        }
        if (oldVersion < 10) {
          await db.execute(
            'ALTER TABLE historical_logs ADD COLUMN reservoir TEXT',
          );
          await db.execute(
            'ALTER TABLE historical_logs ADD COLUMN rainNodeOnline INTEGER',
          );
        }
        if (oldVersion < 11) {
          await db.execute('''
            CREATE TABLE notification_inbox (
              alertId TEXT PRIMARY KEY,
              pH REAL NOT NULL,
              createdAt TEXT NOT NULL,
              isRead INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE weather_location (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              name TEXT NOT NULL,
              latitude REAL NOT NULL,
              longitude REAL NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE local_history_deletions (
              recordId TEXT PRIMARY KEY,
              deletedAt TEXT NOT NULL
            )
          ''');
        }
      },
    );
  }

  Future<void> _migrateScheduledHistoryIdentities(Database db) async {
    await db.execute("ALTER TABLE historical_logs ADD COLUMN intervalKey TEXT");
    await db.execute(
      "ALTER TABLE historical_logs ADD COLUMN recordType TEXT NOT NULL DEFAULT 'scheduled'",
    );
    await db.execute("ALTER TABLE historical_logs ADD COLUMN recordId TEXT");
    await db.execute(
      "ALTER TABLE historical_logs ADD COLUMN source TEXT NOT NULL DEFAULT 'app'",
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS history_capture_state (
        id INTEGER PRIMARY KEY,
        lastIntervalKey TEXT
      )
    ''');

    final rows = await db.query(
      'historical_logs',
      orderBy: 'timestamp ASC, id ASC',
    );
    final keptIds = <String>{};
    for (final row in rows) {
      final id = row['id'] as int;
      final timestamp = DateTime.tryParse(row['timestamp'] as String);
      final batch = row['batchNumber'] as int?;
      if (timestamp == null) {
        await db.delete('historical_logs', where: 'id = ?', whereArgs: [id]);
        continue;
      }
      final intervalKey = legacyManilaHalfHourIntervalKey(timestamp);
      final recordId = batch == null
          ? 'legacy_$id'
          : scheduledSnapshotRecordId(
              batchNumber: batch,
              intervalKey: intervalKey,
            );
      if (!keptIds.add(recordId)) {
        await db.delete('historical_logs', where: 'id = ?', whereArgs: [id]);
        continue;
      }
      await db.update(
        'historical_logs',
        {
          'intervalKey': intervalKey,
          'recordType': scheduledSnapshotRecordType,
          'recordId': recordId,
          'timestamp': legacyManilaHalfHourStartUtc(
            timestamp,
          ).toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_historical_logs_record_id ON historical_logs(recordId)',
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
        cloudSynced INTEGER NOT NULL DEFAULT 0,
        intervalKey TEXT,
        recordType TEXT NOT NULL DEFAULT 'scheduled',
        recordId TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'app',
        reservoir TEXT,
        rainNodeOnline INTEGER
      )
    ''');
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_historical_logs_record_id ON historical_logs(recordId)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS history_capture_state (
        id INTEGER PRIMARY KEY,
        lastIntervalKey TEXT
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
    await db.execute('''
      CREATE TABLE notification_inbox (
        alertId TEXT PRIMARY KEY,
        pH REAL NOT NULL,
        createdAt TEXT NOT NULL,
        isRead INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE weather_location (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        name TEXT NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE local_history_deletions (
        recordId TEXT PRIMARY KEY,
        deletedAt TEXT NOT NULL
      )
    ''');
  }

  // Security Configuration Queries
  Future<void> saveSecurityConfig({
    String? customPin,
    required bool isBiometricsEnabled,
  }) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert('app_security', {
      'id': 1,
      'customPin': customPin,
      'isBiometricsEnabled': isBiometricsEnabled ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getSecurityConfig() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query(
      'app_security',
      where: 'id = ?',
      whereArgs: [1],
    );
    if (result.isNotEmpty) {
      return {
        'customPin': result.first['customPin'] as String?,
        'isBiometricsEnabled':
            (result.first['isBiometricsEnabled'] as int) == 1,
      };
    }
    return null;
  }

  Map<String, Object?> _logToRow(
    HistoricalData log, {
    required bool cloudSynced,
  }) {
    return {
      'timestamp': log.timestamp.toUtc().toIso8601String(),
      'pH': log.pH,
      'temperature': log.temperature,
      'waterLevel': log.waterLevel,
      'tds': log.tds,
      'batchNumber': log.batchNumber,
      'bed1': log.bed1 != null ? jsonEncode(log.bed1!.toMap()) : null,
      'bed2': log.bed2 != null ? jsonEncode(log.bed2!.toMap()) : null,
      'cloudSynced': cloudSynced ? 1 : 0,
      'intervalKey': log.intervalKey,
      'recordType': log.recordType,
      'recordId': log.identity,
      'source': log.source,
      'reservoir': normalizeReservoirLevel(log.reservoir.level),
      'rainNodeOnline': log.reservoir.online ? 1 : 0,
    };
  }

  // Historical Logs Queries
  Future<bool> insertLog(HistoricalData log, {bool cloudSynced = false}) async {
    final db = await instance.database;
    if (db == null) return false;
    final rowId = await db.insert(
      'historical_logs',
      _logToRow(log, cloudSynced: cloudSynced),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return rowId != 0;
  }

  Future<bool> insertLogIfMissing(
    HistoricalData log, {
    bool cloudSynced = false,
  }) async {
    final db = await instance.database;
    if (db == null) return false;
    if (await isLocalLogDeleted(log.identity)) return false;
    final existingRows = await db.query(
      'historical_logs',
      where: 'recordId = ?',
      whereArgs: [log.identity],
      limit: 1,
    );
    if (existingRows.isEmpty) {
      return insertLog(log, cloudSynced: cloudSynced);
    }
    final existing = _logFromRow(existingRows.first);
    final replace = shouldReplaceHistoryRecord(
      existing: {
        'source': existing.source,
        'readingsComplete': existing.readingsComplete,
      },
      incoming: {
        'source': log.source,
        'readingsComplete': log.readingsComplete,
      },
    );
    if (replace) {
      final existingSynced = existingRows.first['cloudSynced'] == 1;
      await db.update(
        'historical_logs',
        _logToRow(log, cloudSynced: cloudSynced || existingSynced),
        where: 'recordId = ?',
        whereArgs: [log.identity],
      );
      return true;
    }
    if (cloudSynced) {
      await db.update(
        'historical_logs',
        {'cloudSynced': 1},
        where: 'recordId = ?',
        whereArgs: [log.identity],
      );
    }
    return false;
  }

  HistoricalData _logFromRow(Map<String, Object?> row) {
    final bed1 = _decodeBedData(row['bed1'] as String?);
    final bed2 = _decodeBedData(row['bed2'] as String?);
    return HistoricalData(
      timestamp: DateTime.parse(row['timestamp'] as String),
      pH: (row['pH'] as num).toDouble(),
      temperature: row['temperature'] as String,
      waterLevel: row['waterLevel'] as String,
      tds: (row['tds'] as num?)?.toDouble() ?? 0.0,
      batchNumber: row['batchNumber'] as int?,
      bed1: bed1,
      bed2: bed2,
      reservoir: ReservoirReading.fromSources(
        shared: row['reservoir'],
        online: row['rainNodeOnline'],
        bed1: row['bed1'] as String?,
        bed2: row['bed2'] as String?,
      ),
      intervalKey: row['intervalKey'] as String?,
      recordType: (row['recordType'] as String?) ?? scheduledSnapshotRecordType,
      recordId: row['recordId'] as String?,
      source: (row['source'] as String?) ?? 'app',
    );
  }

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

  Future<void> markLogCloudSynced(HistoricalData log) async {
    final db = await instance.database;
    if (db == null) return;
    await db.update(
      'historical_logs',
      {'cloudSynced': 1},
      where: 'recordId = ?',
      whereArgs: [log.identity],
    );
  }

  Future<String?> getLastCapturedIntervalKey() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query(
      'history_capture_state',
      where: 'id = ?',
      whereArgs: [1],
    );
    if (result.isEmpty) return null;
    return result.first['lastIntervalKey'] as String?;
  }

  Future<void> saveLastCapturedIntervalKey(String intervalKey) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert('history_capture_state', {
      'id': 1,
      'lastIntervalKey': intervalKey,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    final result = await db.query(
      'historical_logs',
      where: 'batchNumber = ?',
      whereArgs: [batchNumber],
      orderBy: 'timestamp DESC',
    );
    return result.map(_logFromRow).toList();
  }

  Future<bool> deleteLocalLog(String recordId) async {
    final db = await instance.database;
    if (db == null) throw StateError('Local history database is unavailable.');
    final deleted = await db.transaction((transaction) async {
      await transaction.insert('local_history_deletions', {
        'recordId': recordId,
        'deletedAt': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return transaction.delete(
        'historical_logs',
        where: 'recordId = ?',
        whereArgs: [recordId],
      );
    });
    return deleted > 0;
  }

  Future<bool> isLocalLogDeleted(String recordId) async {
    final db = await instance.database;
    if (db == null) throw StateError('Local history database is unavailable.');
    final rows = await db.query(
      'local_history_deletions',
      where: 'recordId = ?',
      whereArgs: [recordId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> insertPhAlert({
    required String alertId,
    required double ph,
    required DateTime createdAt,
  }) async {
    final db = await instance.database;
    if (db == null) throw StateError('Notification inbox is unavailable.');
    await db.insert('notification_inbox', {
      'alertId': alertId,
      'pH': ph,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'isRead': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<PhAlert>> getPhAlerts() async {
    final db = await instance.database;
    if (db == null) throw StateError('Notification inbox is unavailable.');
    final rows = await db.query(
      'notification_inbox',
      orderBy: 'createdAt DESC',
    );
    return rows.map(PhAlert.fromRow).toList();
  }

  Future<int> getUnreadPhAlertCount() async {
    final db = await instance.database;
    if (db == null) throw StateError('Notification inbox is unavailable.');
    final rows = await db.query(
      'notification_inbox',
      columns: ['COUNT(*) AS count'],
      where: 'isRead = 0',
    );
    return (rows.first['count'] as int?) ?? 0;
  }

  Future<void> markPhAlertRead(String alertId) async {
    final db = await instance.database;
    if (db == null) throw StateError('Notification inbox is unavailable.');
    await db.update(
      'notification_inbox',
      {'isRead': 1},
      where: 'alertId = ?',
      whereArgs: [alertId],
    );
  }

  Future<void> clearPhAlerts() async {
    final db = await instance.database;
    if (db == null) throw StateError('Notification inbox is unavailable.');
    await db.delete('notification_inbox');
  }

  Future<WeatherLocation?> getWeatherLocation() async {
    final db = await instance.database;
    if (db == null) return null;
    final rows = await db.query('weather_location', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return WeatherLocation(
      name: row['name'] as String,
      latitude: (row['latitude'] as num).toDouble(),
      longitude: (row['longitude'] as num).toDouble(),
    );
  }

  Future<void> saveWeatherLocation(WeatherLocation location) async {
    final db = await instance.database;
    if (db == null) {
      throw StateError('Weather location storage is unavailable.');
    }
    await db.insert('weather_location', {
      'id': 1,
      'name': location.name,
      'latitude': location.latitude,
      'longitude': location.longitude,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // Planting Runs History Queries
  Future<void> insertPlantingRecord(
    PlantingRecord record, {
    bool cloudSynced = false,
  }) async {
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
    final result = await db.query(
      'planting_history',
      orderBy: 'batchNumber ASC',
    );
    return result
        .map(
          (json) => PlantingRecord(
            batchNumber: json['batchNumber'] as int,
            startDate: DateTime.parse(json['startDate'] as String),
            endDate: DateTime.parse(json['endDate'] as String),
            totalDays: json['totalDays'] as int,
          ),
        )
        .toList();
  }

  // Session State Persistence
  Future<void> saveActiveSession(DateTime startDate, int batchNumber) async {
    final db = await instance.database;
    if (db == null) return;
    await db.insert('active_session', {
      'id': 1,
      'startDate': startDate.toIso8601String(),
      'batchNumber': batchNumber,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<DateTime?> getActiveSession() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query(
      'active_session',
      where: 'id = ?',
      whereArgs: [1],
    );
    if (result.isNotEmpty) {
      return DateTime.parse(result.first['startDate'] as String);
    }
    return null;
  }

  Future<int?> getActiveBatchNumber() async {
    final db = await instance.database;
    if (db == null) return null;
    final result = await db.query(
      'active_session',
      where: 'id = ?',
      whereArgs: [1],
    );
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
    await db.insert('active_ip', {
      'id': 1,
      'ip': ip,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    if (!isValidPhThresholds(minPh, maxPh)) return;
    final db = await instance.database;
    if (db == null) return;
    await db.insert('settings_config', {
      'id': 1,
      'minPh': minPh,
      'maxPh': maxPh,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, double>> getSettingsConfig() async {
    final db = await instance.database;
    if (db == null) return {'minPh': 5.5, 'maxPh': 7.0};
    final result = await db.query(
      'settings_config',
      where: 'id = ?',
      whereArgs: [1],
    );
    if (result.isNotEmpty) {
      final minimum = (result.first['minPh'] as num).toDouble();
      final maximum = (result.first['maxPh'] as num).toDouble();
      if (isValidPhThresholds(minimum, maximum)) {
        return {'minPh': minimum, 'maxPh': maximum};
      }
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
    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
    );

    await _notificationsPlugin.initialize(settings: settings);

    _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  static Future<void> showPhAlertNotification(
    double ph, {
    required String alertId,
  }) async {
    if (kIsWeb) return;

    try {
      await DatabaseHelper.instance.insertPhAlert(
        alertId: alertId,
        ph: ph,
        createdAt: DateTime.now(),
      );
    } catch (error, stackTrace) {
      debugPrint('Could not save pH alert to the local inbox: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'ph_alerts_channel',
          'pH Level Alerts',
          channelDescription: 'Notifications for critical pH level limits',
          importance: Importance.max,
          priority: Priority.high,
        );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
    );

    await _notificationsPlugin.show(
      id: int.tryParse(alertId) ?? DateTime.now().millisecondsSinceEpoch,
      title: '⚠️ Critical pH Alert',
      body:
          'pH level has remained outside the configured range (${ph.toStringAsFixed(2)}) for more than 5 minutes.',
      notificationDetails: details,
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  final ValueChanged<int> onUnreadCountChanged;

  const NotificationsScreen({super.key, required this.onUnreadCountChanged});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<PhAlert>? _alerts;
  Object? _loadError;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAlerts());
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_loadAlerts()),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAlerts() async {
    try {
      final alerts = await DatabaseHelper.instance.getPhAlerts();
      if (!mounted) return;
      setState(() {
        _alerts = alerts;
        _loadError = null;
      });
      widget.onUnreadCountChanged(
        alerts.where((alert) => !alert.isRead).length,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  Future<void> _markRead(PhAlert alert) async {
    if (alert.isRead) return;
    try {
      await DatabaseHelper.instance.markPhAlertRead(alert.alertId);
      await _loadAlerts();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not mark alert as read: $error')),
      );
    }
  }

  Future<void> _clearAlerts() async {
    try {
      await DatabaseHelper.instance.clearPhAlerts();
      await _loadAlerts();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not clear notifications: $error')),
      );
    }
  }

  String _formatDate(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final alerts = _alerts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Notifications',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
              ),
              TextButton.icon(
                onPressed: alerts == null || alerts.isEmpty
                    ? null
                    : _clearAlerts,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear'),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'Tap an alert to mark it as read. Clearing removes only this inbox.',
            style: TextStyle(color: Colors.black54),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loadError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Notifications could not be loaded.'),
                      TextButton(
                        onPressed: () => unawaited(_loadAlerts()),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : alerts == null
              ? const Center(child: CircularProgressIndicator())
              : alerts.isEmpty
              ? const Center(child: Text('No critical pH alerts yet.'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: alerts.length,
                  itemBuilder: (context, index) {
                    final alert = alerts[index];
                    return Card(
                      color: alert.isRead
                          ? Colors.white
                          : const Color(0xFFFFF1F0),
                      child: ListTile(
                        leading: Icon(
                          Icons.warning_amber_rounded,
                          color: alert.isRead ? Colors.grey : Colors.red,
                        ),
                        title: Text(
                          'Critical pH alert · ${alert.ph.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontWeight: alert.isRead
                                ? FontWeight.normal
                                : FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(_formatDate(alert.createdAt)),
                        trailing: alert.isRead
                            ? null
                            : const Icon(
                                Icons.circle,
                                size: 10,
                                color: Colors.red,
                              ),
                        onTap: () => _markRead(alert),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class WeatherHomeCard extends StatefulWidget {
  const WeatherHomeCard({super.key});

  @override
  State<WeatherHomeCard> createState() => _WeatherHomeCardState();
}

class _WeatherHomeCardState extends State<WeatherHomeCard> {
  WeatherConditions? _conditions;
  String? _locationName;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final location = await DatabaseHelper.instance.getWeatherLocation();
      if (!mounted) return;
      if (location == null) {
        setState(() {
          _locationName = null;
          _conditions = null;
          _loading = false;
        });
        return;
      }
      setState(() => _locationName = location.name);
      final conditions = await WeatherService.fetch(location);
      if (!mounted) return;
      setState(() {
        _conditions = conditions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _openDetails() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const WeatherDetailScreen()),
    ).then((_) => _refresh());
  }

  @override
  Widget build(BuildContext context) {
    final conditions = _conditions;
    final temperature = conditions?.temperature;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: const Color(0xFF123F3B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        onTap: _openDetails,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              Icon(
                weatherIcon(conditions?.weatherCode),
                size: 36,
                color: const Color(0xFF7DE6D2),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _locationName ?? 'Local weather',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _loading
                          ? 'Loading weather…'
                          : _error != null
                          ? 'Weather unavailable · tap to retry'
                          : temperature == null
                          ? 'Choose a location to get weather'
                          : weatherDescription(conditions?.weatherCode),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB7D7D1),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF7DE6D2),
                  ),
                )
              else if (temperature != null)
                Text(
                  '${temperature.toStringAsFixed(0)}°',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                )
              else
                const Icon(Icons.chevron_right, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}

class WeatherDetailScreen extends StatefulWidget {
  const WeatherDetailScreen({super.key});

  @override
  State<WeatherDetailScreen> createState() => _WeatherDetailScreenState();
}

class _WeatherDetailScreenState extends State<WeatherDetailScreen> {
  final TextEditingController _searchController = TextEditingController();
  WeatherLocation? _location;
  WeatherConditions? _conditions;
  List<WeatherLocation> _matches = [];
  Object? _error;
  bool _loading = false;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSavedLocation());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedLocation() async {
    try {
      final saved = await DatabaseHelper.instance.getWeatherLocation();
      if (!mounted || saved == null) return;
      _searchController.text = saved.name;
      setState(() => _location = saved);
      await _loadWeather(saved);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _searchLocations() async {
    setState(() {
      _searching = true;
      _error = null;
      _matches = [];
    });
    try {
      final matches = await WeatherService.searchLocations(
        _searchController.text,
      );
      if (!mounted) return;
      setState(() => _matches = matches);
      if (matches.isEmpty) setState(() => _error = 'No matching places found.');
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _selectLocation(WeatherLocation location) async {
    setState(() {
      _location = location;
      _matches = [];
      _searchController.text = location.name;
    });
    try {
      await DatabaseHelper.instance.saveWeatherLocation(location);
      await _loadWeather(location);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _loadWeather(WeatherLocation location) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final conditions = await WeatherService.fetch(location);
      if (!mounted) return;
      setState(() {
        _conditions = conditions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  String _dayName(DateTime date) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[date.weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    final conditions = _conditions;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Weather'),
        actions: [
          IconButton(
            tooltip: 'Refresh weather',
            onPressed: _location == null || _loading
                ? null
                : () => _loadWeather(_location!),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Choose a location',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Search for and select a city. Weather is provided by Open-Meteo; Hydrodeck does not access your device location.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _searchLocations(),
                  decoration: const InputDecoration(
                    labelText: 'City or place',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Search locations',
                onPressed: _searching ? null : _searchLocations,
                icon: _searching
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
              ),
            ],
          ),
          if (_matches.isNotEmpty)
            ..._matches.map(
              (match) => ListTile(
                leading: const Icon(Icons.location_on_outlined),
                title: Text(match.name),
                onTap: () => _selectLocation(match),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Weather unavailable: $_error',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(36),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (conditions != null) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0D3532), Color(0xFF176D5E)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conditions.location.name,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        weatherIcon(conditions.weatherCode),
                        color: const Color(0xFF7DE6D2),
                        size: 54,
                      ),
                      const SizedBox(width: 18),
                      Text(
                        conditions.temperature == null
                            ? '—'
                            : '${conditions.temperature!.toStringAsFixed(0)}°',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 48,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    weatherDescription(conditions.weatherCode),
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 20,
                    runSpacing: 12,
                    children: [
                      _WeatherMetric(
                        label: 'Feels like',
                        value: conditions.feelsLike == null
                            ? '—'
                            : '${conditions.feelsLike!.toStringAsFixed(0)}°',
                      ),
                      _WeatherMetric(
                        label: 'Humidity',
                        value: conditions.humidity == null
                            ? '—'
                            : '${conditions.humidity}%',
                      ),
                      _WeatherMetric(
                        label: 'Wind',
                        value: conditions.windSpeed == null
                            ? '—'
                            : '${conditions.windSpeed!.toStringAsFixed(0)} km/h',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (conditions.forecast.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text(
                '5-day forecast',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...conditions.forecast.map(
                (day) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    weatherIcon(day.weatherCode),
                    color: const Color(0xFF168AAD),
                  ),
                  title: Text(_dayName(day.date)),
                  subtitle: Text(
                    '${weatherDescription(day.weatherCode)}'
                    '${day.precipitationProbability == null ? '' : ' · ${day.precipitationProbability}% rain'}',
                  ),
                  trailing: Text(
                    '${day.minimumTemperature?.toStringAsFixed(0) ?? '—'}° / '
                    '${day.maximumTemperature?.toStringAsFixed(0) ?? '—'}°',
                  ),
                ),
              ),
            ],
          ] else if (_location == null && _error == null)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Text('Select a location to see current weather.'),
            ),
        ],
      ),
    );
  }
}

class _WeatherMetric extends StatelessWidget {
  final String label;
  final String value;

  const _WeatherMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  );
}

IconData weatherIcon(int? code) => switch (code) {
  0 || 1 => Icons.wb_sunny_outlined,
  2 || 3 => Icons.cloud_outlined,
  45 || 48 => Icons.foggy,
  51 || 53 || 55 || 56 || 57 => Icons.grain,
  61 || 63 || 65 || 66 || 67 || 80 || 81 || 82 => Icons.umbrella_outlined,
  71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit,
  95 || 96 || 99 => Icons.thunderstorm_outlined,
  _ => Icons.cloud_outlined,
};

class ReservoirReading {
  final String level;
  final bool online;

  const ReservoirReading({this.level = 'not_full', this.online = false});

  Map<String, dynamic> toMap() => {
    'level': normalizeReservoirLevel(level),
    'online': online,
  };

  static ReservoirReading fromSources({
    dynamic shared,
    dynamic online,
    dynamic bed1,
    dynamic bed2,
  }) {
    Map<String, dynamic>? asMap(dynamic value) {
      if (value is Map) return Map<String, dynamic>.from(value);
      if (value is String && value.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is Map) return Map<String, dynamic>.from(decoded);
        } catch (_) {}
      }
      return null;
    }

    bool? asBool(dynamic value) {
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.toLowerCase();
        if (normalized == 'true' || normalized == 'on' || normalized == '1') {
          return true;
        }
        if (normalized == 'false' || normalized == 'off' || normalized == '0') {
          return false;
        }
      }
      return null;
    }

    final sharedMap = asMap(shared);
    final legacyBed1 = asMap(bed1);
    final legacyBed2 = asMap(bed2);
    final sharedLevel =
        sharedMap?['level'] ?? (shared is String ? shared : null);
    final legacyLevel = legacyBed1?['reservoir'] ?? legacyBed2?['reservoir'];
    final sharedOnline = asBool(sharedMap?['online'] ?? online);
    final legacyOnline = asBool(
      legacyBed1?['rainNodeOnline'] ?? legacyBed2?['rainNodeOnline'],
    );

    return ReservoirReading(
      level: normalizeReservoirLevel(sharedLevel ?? legacyLevel),
      online: sharedOnline ?? legacyOnline ?? false,
    );
  }
}

String normalizeReservoirLevel(dynamic value) =>
    switch (value?.toString().trim().toLowerCase()) {
      'full' => 'full',
      'not_full' || 'above_50' || '50_or_below' => 'not_full',
      _ => 'not_full',
    };

class GrowBedReading {
  final double temperature;
  final bool temperatureValid;
  final double ph;
  final double tds;
  final bool waterFull;

  const GrowBedReading({
    required this.temperature,
    this.temperatureValid = true,
    required this.ph,
    required this.tds,
    required this.waterFull,
  });

  factory GrowBedReading.empty() => const GrowBedReading(
    temperature: 0.0,
    temperatureValid: false,
    ph: 6.0,
    tds: 0.0,
    waterFull: false,
  );

  factory GrowBedReading.fromMap(Map<String, dynamic> map) {
    final rawTemperature = map['temp'];
    final parsedTemperature = rawTemperature is num
        ? rawTemperature.toDouble()
        : double.tryParse(rawTemperature?.toString() ?? '');
    final temperatureValid =
        parsedTemperature != null &&
        isValidTemperatureReading(parsedTemperature) &&
        map['tempValid'] != false;
    final temperature = temperatureValid ? parsedTemperature : 0.0;
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
      temperatureValid: temperatureValid,
      ph: ph,
      tds: tds,
      waterFull: waterFull,
    );
  }

  Map<String, dynamic> toMap() => {
    'temp': temperature,
    'tempValid': temperatureValid,
    'ph': ph,
    'tds': tds,
    'water': waterFull ? 'full' : 'low',
  };
}

String reservoirLabel(String level) => switch (normalizeReservoirLevel(level)) {
  'full' => 'Full',
  _ => 'Not full',
};

Color reservoirColor(String level) => switch (normalizeReservoirLevel(level)) {
  'full' => const Color(0xFF2E7D32),
  _ => Colors.orange,
};

String dashboardConnectionStatus({
  required bool localTelemetryFresh,
  required bool firebaseHeartbeatFresh,
}) => localTelemetryFresh
    ? 'Connected locally'
    : firebaseHeartbeatFresh
    ? 'Online'
    : 'ESP32 offline';

bool shouldApplyFirebaseDeviceState({required bool localTelemetryFresh}) =>
    !localTelemetryFresh;

bool shouldShowWifiSetupPrompt({
  required bool localDeviceReachable,
  required bool cloudReachable,
}) => !localDeviceReachable && !cloudReachable;

bool shouldShowOfflineHotspotPrompt({
  required bool? firebaseConnected,
  required bool localDeviceReachable,
}) => firebaseConnected == false && !localDeviceReachable;

String? dashboardOfflineBannerMessage({
  required bool? firebaseConnected,
  required bool localDeviceReachable,
}) {
  if (firebaseConnected != false) return null;
  return localDeviceReachable
      ? 'Firebase cloud is unavailable. Connected locally: live ESP32 readings '
            'and pump control may still work. Cloud logs and history cannot be '
            'loaded or synced until cloud access returns; history already saved '
            'on this phone is kept.'
      : 'Internet/Firebase cloud is unavailable, and the ESP32 is not reachable '
            'locally. Connect to the ESP32 hotspot to try local monitoring and '
            'control.';
}

bool reportedActuatorStateConfirmsRequest({
  required bool requestedState,
  required bool reportedState,
}) => requestedState == reportedState;

class HydrodeckTelemetry {
  final GrowBedReading bed1;
  final GrowBedReading bed2;
  final ReservoirReading reservoir;
  final bool? wifiConnected;
  final bool? firebaseReady;
  final bool? firebaseHeartbeatFresh;
  final bool growLightOn;
  final Map<String, bool> actuatorStates;

  const HydrodeckTelemetry({
    required this.bed1,
    required this.bed2,
    this.reservoir = const ReservoirReading(),
    this.wifiConnected,
    this.firebaseReady,
    this.firebaseHeartbeatFresh,
    required this.growLightOn,
    required this.actuatorStates,
  });

  static bool _readBoolLike(
    Map<String, dynamic> map,
    List<String> keys, {
    bool fallback = false,
  }) {
    for (final key in keys) {
      final value = map[key];
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.toLowerCase();
        if (normalized == 'true' || normalized == 'on' || normalized == '1') {
          return true;
        }
        if (normalized == 'false' || normalized == 'off' || normalized == '0') {
          return false;
        }
      }
    }
    return fallback;
  }

  factory HydrodeckTelemetry.fromJson(Map<String, dynamic> json) {
    final wireMap = Map<String, dynamic>.from(json);
    final reservoir = ReservoirReading.fromSources(
      shared: wireMap['reservoir'],
      online: wireMap['rainNodeOnline'],
      bed1: wireMap['bed1'],
      bed2: wireMap['bed2'],
    );

    final bed1Map = {
      'temp':
          wireMap['temp1'] ??
          wireMap['bed1']?['temp'] ??
          wireMap['set1']?['temp'],
      'tempValid':
          wireMap['temp1Valid'] ??
          wireMap['bed1']?['tempValid'] ??
          wireMap['set1']?['tempValid'],
      'ph':
          wireMap['ph1'] ??
          wireMap['bed1']?['ph'] ??
          wireMap['set1']?['ph'] ??
          6.0,
      'tds':
          wireMap['tds1'] ??
          wireMap['bed1']?['tds'] ??
          wireMap['set1']?['tds'] ??
          0.0,
      'water':
          wireMap['water1'] ??
          wireMap['bed1']?['water'] ??
          wireMap['set1']?['water'] ??
          'low',
    };

    final bed2Map = {
      'temp':
          wireMap['temp2'] ??
          wireMap['bed2']?['temp'] ??
          wireMap['set2']?['temp'],
      'tempValid':
          wireMap['temp2Valid'] ??
          wireMap['bed2']?['tempValid'] ??
          wireMap['set2']?['tempValid'],
      'ph':
          wireMap['ph2'] ??
          wireMap['bed2']?['ph'] ??
          wireMap['set2']?['ph'] ??
          6.0,
      'tds':
          wireMap['tds2'] ??
          wireMap['bed2']?['tds'] ??
          wireMap['set2']?['tds'] ??
          0.0,
      'water':
          wireMap['water2'] ??
          wireMap['bed2']?['water'] ??
          wireMap['set2']?['water'] ??
          'low',
    };

    final bed1 = GrowBedReading.fromMap(bed1Map);
    final bed2 = GrowBedReading.fromMap(bed2Map);

    final actuatorMap = Map<String, dynamic>.from(
      wireMap['actuators'] is Map ? wireMap['actuators'] : {},
    );
    final allMap = <String, dynamic>{
      ...Map<String, dynamic>.from(wireMap),
      ...Map<String, dynamic>.from(actuatorMap),
    };

    final growLightOn = _readBoolLike(allMap, const [
      'growLight',
    ], fallback: false);

    final actuatorStates = {
      for (final name in _actuatorControlKeys.keys)
        name: _readBoolLike(allMap, [name]),
    };

    return HydrodeckTelemetry(
      bed1: bed1,
      bed2: bed2,
      reservoir: reservoir,
      wifiConnected: wireMap['wifiConnected'] is bool
          ? wireMap['wifiConnected'] as bool
          : null,
      firebaseReady: wireMap['firebaseReady'] is bool
          ? wireMap['firebaseReady'] as bool
          : null,
      firebaseHeartbeatFresh: wireMap['firebaseHeartbeatFresh'] is bool
          ? wireMap['firebaseHeartbeatFresh'] as bool
          : null,
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
    description:
        'Keeps ESP32 connection live and records metrics continuous logs.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onBackgroundServiceStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      notificationChannelId: 'hydrodeck_bg_service',
      initialNotificationTitle: 'Hydrodeck Service Active',
      initialNotificationContent:
          'Monitoring ESP32 and logging sensors in background...',
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
  initializeHydrodeckTimeZones();

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
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
  ReservoirReading lastReservoir = const ReservoirReading();

  bool isAppClosed = false;
  bool isPlantingActive = false;
  int? activeBatchNumber;

  double minPhThreshold = 5.5;
  double maxPhThreshold = 7.0;

  final criticalPhEpisode = CriticalPhEpisode();

  bool isPolling = false; // Prevents timer stack overlap

  double? readValidBed2Ph(Map<String, dynamic> data) {
    final bed2 = data['bed2'];
    final bed2Map = bed2 is Map ? Map<String, dynamic>.from(bed2) : null;
    final value = data['ph2'] ?? bed2Map?['ph'];
    final valid = data['ph2Valid'] ?? bed2Map?['phValid'];
    if (valid == false) return null;
    final ph = value is num ? value.toDouble() : double.tryParse('$value');
    if (ph == null || !ph.isFinite || ph < 0 || ph > 14) return null;
    return ph;
  }

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
      lastReservoir = logs.first.reservoir;
      lastBed2 = GrowBedReading(
        temperature:
            double.tryParse(
              logs.first.temperature.replaceAll(RegExp(r'[^0-9.\-]'), ''),
            ) ??
            25.0,
        ph: logs.first.pH,
        tds: logs.first.tds,
        waterFull: lastWater == 'full',
      );
      lastTemp = logs.first.temperature;
      lastWater = logs.first.waterLevel == "Water full" ? "full" : "low";
      lastTds = logs.first.tds;
    }
  } catch (_) {}

  backgroundActive = isPlantingActive || await hasPendingCloudRecords();
  if (!backgroundActive) {
    service.stopSelf();
    return;
  }

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
      final minimumValue = event['minPh'];
      final maximumValue = event['maxPh'];
      if (minimumValue is num && maximumValue is num) {
        final minimum = minimumValue.toDouble();
        final maximum = maximumValue.toDouble();
        if (isValidPhThresholds(minimum, maximum)) {
          minPhThreshold = minimum;
          maxPhThreshold = maximum;
          unawaited(
            DatabaseHelper.instance.saveSettingsConfig(minimum, maximum),
          );
        }
      }
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

  Future<Map<String, dynamic>?> fetchStatus(
    String host,
    Duration timeout,
  ) async {
    try {
      final res = await http
          .get(
            Uri.parse('http://$host/status'),
            headers: {'Connection': 'close'},
          )
          .timeout(timeout);

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
    final reservoir = ReservoirReading.fromSources(
      shared: data['reservoir'],
      online: data['rainNodeOnline'],
      bed1: data['bed1'],
      bed2: data['bed2'],
    );
    final reservoirLevel = reservoir.level;
    final rainNodeOnline = reservoir.online;
    final bed1 = {
      'temp': data['temp1'] ?? data['bed1']?['temp'],
      'tempValid': data['temp1Valid'] ?? data['bed1']?['tempValid'],
      'ph': data['ph1'] ?? data['bed1']?['ph'] ?? 6.0,
      'tds': data['tds1'] ?? data['bed1']?['tds'] ?? 0.0,
      'water': data['water1'] ?? data['bed1']?['water'] ?? 'low',
    };
    final bed2 = {
      'temp': data['temp2'] ?? data['bed2']?['temp'],
      'tempValid': data['temp2Valid'] ?? data['bed2']?['tempValid'],
      'ph': data['ph2'] ?? data['bed2']?['ph'] ?? 6.0,
      'tds': data['tds2'] ?? data['bed2']?['tds'] ?? 0.0,
      'water': data['water2'] ?? data['bed2']?['water'] ?? 'low',
    };

    final bed2Ph = bed2['ph'] is num ? (bed2['ph'] as num).toDouble() : 6.0;
    final bed2Temp = bed2['temp'] is num
        ? (bed2['temp'] as num).toDouble()
        : 25.0;
    final bed2Tds = bed2['tds'] is num ? (bed2['tds'] as num).toDouble() : 0.0;
    final bed2Water = bed2['water'] is String ? bed2['water'] as String : 'low';
    final actuators = Map<String, dynamic>.from(
      data['actuators'] is Map ? data['actuators'] as Map : data,
    );
    final growLightFlag =
        actuators['growLight'] ??
        data['grow_light'] ??
        data['growLight'] ??
        false;

    return {
      'bed1': bed1,
      'bed2': bed2,
      'reservoir': {'level': reservoirLevel, 'online': rainNodeOnline},
      'growLight': growLightFlag,
      'actuators': {
        for (final name in const [
          'waterPump1',
          'phUp1',
          'phDown1',
          'nutrient1',
          'waterPump2',
          'phUp2',
          'phDown2',
          'nutrient2',
        ])
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
    double? currentPhReading;
    String telemetrySource = 'offline';
    bool firebaseHeartbeatFresh = false;
    String cleanTargetIp = sanitizeHost(targetIp);

    // 1. Fast attempt to primary target IP
    final primaryResult = await fetchStatus(
      cleanTargetIp,
      const Duration(milliseconds: 1200),
    );

    if (primaryResult != null) {
      final statusData = Map<String, dynamic>.from(
        primaryResult['data'] as Map,
      );
      currentPhReading = readValidBed2Ph(statusData);
      final normalized = normalizeStatusPayload(statusData);
      final bed1 = GrowBedReading.fromMap(
        normalized['bed1'] as Map<String, dynamic>,
      );
      final bed2 = GrowBedReading.fromMap(
        normalized['bed2'] as Map<String, dynamic>,
      );

      lastBed1 = bed1;
      lastBed2 = bed2;
      lastReservoir = ReservoirReading.fromSources(
        shared: normalized['reservoir'],
      );
      lastGrowLight = HydrodeckTelemetry._readBoolLike(
        {'growLight': normalized['growLight']},
        const ['growLight'],
      );
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
        'reservoir': lastReservoir.toMap(),
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
        "10.0.2.2",
      ].map(sanitizeHost).where((h) => h != cleanTargetIp).toSet().toList();

      final results = await Future.wait(
        fallbackHosts.map(
          (h) => fetchStatus(h, const Duration(milliseconds: 1200)),
        ),
      );

      for (final res in results) {
        if (res != null) {
          final host = res['host'] as String;
          final statusData = Map<String, dynamic>.from(res['data'] as Map);
          currentPhReading = readValidBed2Ph(statusData);
          final normalized = normalizeStatusPayload(statusData);
          final bed1 = GrowBedReading.fromMap(
            normalized['bed1'] as Map<String, dynamic>,
          );
          final bed2 = GrowBedReading.fromMap(
            normalized['bed2'] as Map<String, dynamic>,
          );

          lastBed1 = bed1;
          lastBed2 = bed2;
          lastReservoir = ReservoirReading.fromSources(
            shared: normalized['reservoir'],
          );
          lastGrowLight = HydrodeckTelemetry._readBoolLike(
            {'growLight': normalized['growLight']},
            const ['growLight'],
          );
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
            'reservoir': lastReservoir.toMap(),
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
          databaseURL:
              "https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/",
        ).ref('hydrodeck');

        final snapshot = await dbRef.get().timeout(
          const Duration(milliseconds: 2500),
        );
        if (snapshot.exists && snapshot.value != null) {
          final data = Map<String, dynamic>.from(snapshot.value as Map);
          currentPhReading = readValidBed2Ph(data);
          final telemetry = HydrodeckTelemetry.fromJson(data);
          lastBed1 = telemetry.bed1;
          lastBed2 = telemetry.bed2;
          lastReservoir = telemetry.reservoir;
          lastGrowLight = telemetry.growLightOn;
          lastPh = lastBed2.ph;
          lastTemp = '${lastBed2.temperature.toStringAsFixed(1)}°C';
          lastTds = lastBed2.tds;
          lastWater = lastBed2.waterFull ? 'full' : 'low';
          firebaseConnected = true;
          final lastSeen = data['lastSeen'];
          final heartbeatMillis = _parseHeartbeatMillis(lastSeen);
          final heartbeatFresh = isDeviceHeartbeatFresh(heartbeatMillis);
          firebaseHeartbeatFresh = heartbeatFresh;
          isConnected =
              data['wifiConnected'] == true &&
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

    final notificationTime = DateTime.now();
    if (criticalPhEpisode.shouldNotify(
          ph: currentPhReading,
          minimum: minPhThreshold,
          maximum: maxPhThreshold,
          now: notificationTime,
        ) &&
        isAppClosed) {
      final alertId = criticalPhEpisode.notificationId;
      if (alertId != null) {
        unawaited(
          NotificationHelper.showPhAlertNotification(
            currentPhReading!,
            alertId: alertId,
          ),
        );
      }
      criticalPhEpisode.markNotified();
    }

    service.invoke('telemetryUpdate', {
      'isConnected': isConnected,
      'firebaseConnected': firebaseConnected,
      'firebaseHeartbeatFresh': firebaseHeartbeatFresh,
      'source': telemetrySource,
      'ip': targetIp,
      'ph': lastPh,
      'temp': lastTemp,
      'water': lastWater,
      'tds': lastTds,
      'bed1': lastBed1.toMap(),
      'bed2': lastBed2.toMap(),
      'reservoir': lastReservoir.toMap(),
      'growLight': lastGrowLight,
    });

    isPolling = false;
  });

  String? lastSnapshotIntervalIdentity = await DatabaseHelper.instance
      .getLastCapturedIntervalKey();
  var intervalTaskScheduled = false;

  Future<void> reconcileDueSnapshot() async {
    if (!backgroundActive || !isPlantingActive) {
      await uploadNextUnsyncedRecord();
      return;
    }
    final serverNow = await getServerNow();
    final intervalKey = manilaIntervalKey(serverNow);
    final intervalIdentity = '${activeBatchNumber ?? 0}|$intervalKey';
    if (intervalIdentity == lastSnapshotIntervalIdentity) {
      await uploadNextUnsyncedRecord();
      return;
    }
    final inserted = await captureDueScheduledSnapshot(
      batchNumber: activeBatchNumber,
      now: serverNow,
    );
    if (inserted) {
      lastSnapshotIntervalIdentity = intervalIdentity;
      final logs = await DatabaseHelper.instance.getLogsForBatch(
        activeBatchNumber!,
      );
      final recordId = scheduledSnapshotRecordId(
        batchNumber: activeBatchNumber!,
        intervalKey: intervalKey,
      );
      final snapshot = logs.firstWhere((log) => log.recordId == recordId);
      service.invoke('newSnapshotLogged', {
        'timestamp': snapshot.timestamp.toIso8601String(),
        'pH': snapshot.pH,
        'temperature': snapshot.temperature,
        'waterLevel': snapshot.waterLevel,
        'tds': snapshot.tds,
        'batchNumber': snapshot.batchNumber,
        'reservoir': snapshot.reservoir.toMap(),
        'bed1': snapshot.bed1?.toMap(),
        'bed2': snapshot.bed2?.toMap(),
        'intervalKey': snapshot.intervalKey,
        'recordId': snapshot.recordId,
        'recordType': snapshot.recordType,
        'source': snapshot.source,
      });
    }
    await uploadNextUnsyncedRecord();
  }

  Future<void> scheduleNextIntervalTask() async {
    if (intervalTaskScheduled || !backgroundActive) return;
    intervalTaskScheduled = true;
    try {
      final now = await getServerNow();
      final wait = delayUntilNextManilaInterval(now);
      Timer(wait, () async {
        try {
          if (!backgroundActive) return;
          await reconcileDueSnapshot();
          if (!isPlantingActive && !await hasPendingCloudRecords()) {
            backgroundActive = false;
            service.stopSelf();
          }
        } catch (_) {
          // Local logs remain queued if the network or Firestore is unavailable.
        } finally {
          intervalTaskScheduled = false;
          if (backgroundActive) unawaited(scheduleNextIntervalTask());
        }
      });
    } catch (_) {
      intervalTaskScheduled = false;
      Timer(
        const Duration(seconds: 15),
        () => unawaited(scheduleNextIntervalTask()),
      );
    }
  }

  unawaited(scheduleNextIntervalTask());
  unawaited(reconcileDueSnapshot());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeHydrodeckTimeZones();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
    );
  } catch (_) {}

  EmailOTP.config(
    appName: 'Hydrodeck',
    appEmail: 'hydrodecknt@gmail.com',
    otpLength: 6,
    otpType: OTPType.numeric,
    expiry: 0,
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
    password: 'psiq auzg tweh klhj',
  );
  if (_supportsBackgroundService) await NotificationHelper.init();
  runApp(const HydrodeckApp());
}

class HydrodeckApp extends StatefulWidget {
  const HydrodeckApp({super.key});

  @override
  State<HydrodeckApp> createState() => _HydrodeckAppState();
}

class _HydrodeckAppState extends State<HydrodeckApp>
    with WidgetsBindingObserver {
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
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

class _AuthGatekeeperState extends State<AuthGatekeeper>
    with SingleTickerProviderStateMixin {
  bool _loading = true;
  bool _showSignup = true;
  User? _user;
  StreamSubscription<User?>? _authSubscription;
  late final AnimationController _transition;

  @override
  void initState() {
    super.initState();
    _transition = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      final lastSignIn = user?.metadata.lastSignInTime;
      final sessionValid =
          user != null &&
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
        if (MediaQuery.maybeOf(context)?.disableAnimations == true) {
          _transition.value = 1;
        } else {
          unawaited(_transition.forward());
        }
      }
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _transition.dispose();
    super.dispose();
  }

  void _authenticated(User user) {
    setState(() => _user = user);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _HydrodeckSplash();
    if (_user != null) return const MainGatekeeper();
    return _AuthEntryTransition(
      animation: _transition,
      child: _showSignup
          ? SignupScreen(
              onLogin: () => setState(() => _showSignup = false),
              onAuthenticated: _authenticated,
            )
          : LoginScreen(
              onSignup: () => setState(() => _showSignup = true),
              onAuthenticated: _authenticated,
            ),
    );
  }
}

class _HydrodeckSplash extends StatelessWidget {
  const _HydrodeckSplash();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF073B34),
    body: Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF073B34), Color(0xFF0B554B)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        Positioned(top: -80, right: -40, child: _splashCloud(240, 150)),
        Positioned(bottom: -70, left: -60, child: _splashCloud(260, 160)),
        const Positioned(
          top: 88,
          left: 44,
          child: Icon(Icons.water_drop, color: Color(0x557DE6D2), size: 23),
        ),
        const Positioned(
          bottom: 150,
          right: 42,
          child: Icon(Icons.water_drop, color: Color(0x557DE6D2), size: 18),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('hydrodeck_logo.png', width: 140, height: 140),
              const SizedBox(height: 12),
              const Text(
                'HYDRODECK',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'GROW WITH CONFIDENCE',
                style: TextStyle(
                  color: Color(0xFFB7D7D1),
                  fontSize: 11,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  static Widget _splashCloud(double width, double height) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: const Color(0x223DB5A1),
      borderRadius: BorderRadius.circular(height),
    ),
  );
}

class _AuthEntryTransition extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;

  const _AuthEntryTransition({required this.animation, required this.child});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final progress = Curves.easeInOutCubic.transform(animation.value);
      final size = MediaQuery.sizeOf(context);
      return Stack(
        children: [
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(0, size.height * 0.12 * (1 - progress)),
              child: child,
            ),
          ),
          if (progress < 1)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Color.fromRGBO(7, 59, 52, 1 - progress),
                ),
              ),
            ),
          if (progress < 1)
            Positioned(
              top: 14 + (size.height - 220) * 0.5 * (1 - progress),
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Opacity(
                  opacity: 1 - progress,
                  child: Center(
                    child: Transform.scale(
                      scale: 1 - 0.5 * progress,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset(
                            'hydrodeck_logo.png',
                            width: 140,
                            height: 140,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'HYDRODECK',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class SignupScreen extends StatefulWidget {
  final VoidCallback onLogin;
  final ValueChanged<User> onAuthenticated;
  const SignupScreen({
    super.key,
    required this.onLogin,
    required this.onAuthenticated,
  });

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _pin = TextEditingController();
  final _emailFocus = FocusNode();
  final _phoneFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  final _pinFocus = FocusNode();
  String? _emailError;
  String? _phoneError;
  String? _passwordError;
  String? _confirmError;
  String? _pinError;
  bool _emailTouched = false;
  bool _phoneTouched = false;
  bool _passwordTouched = false;
  bool _confirmTouched = false;
  bool _pinTouched = false;
  bool _acceptedPolicies = false;
  bool _consentError = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailFocus.addListener(() {
      if (!_emailFocus.hasFocus) _validateSignupEmail(onBlur: true);
    });
    _phoneFocus.addListener(() {
      if (!_phoneFocus.hasFocus) _validateSignupPhone(onBlur: true);
    });
    _passwordFocus.addListener(() {
      if (!_passwordFocus.hasFocus) _validateSignupPassword(onBlur: true);
    });
    _confirmFocus.addListener(() {
      if (!_confirmFocus.hasFocus) _validateSignupConfirmation(onBlur: true);
    });
    _pinFocus.addListener(() {
      if (!_pinFocus.hasFocus) _validateSignupPin(onBlur: true);
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    _confirm.dispose();
    _pin.dispose();
    _emailFocus.dispose();
    _phoneFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  bool _validatePolicyConsent() {
    final accepted = _acceptedPolicies;
    setState(() => _consentError = !accepted);
    return accepted;
  }

  Future<void> _submitSignup() async {
    if (!_validatePolicyConsent()) return;
    await _signup();
  }

  // Keep each field's inline validation quiet until it has lost focus once.
  void _validateSignupEmail({bool onBlur = false}) {
    if (onBlur) _emailTouched = true;
    if (_emailTouched) {
      setState(() => _emailError = validateEmailField(_email.text));
    }
  }

  void _validateSignupPhone({bool onBlur = false}) {
    if (onBlur) _phoneTouched = true;
    if (_phoneTouched) {
      setState(() => _phoneError = validateSignupPhoneField(_phone.text));
    }
  }

  void _validateSignupPassword({bool onBlur = false}) {
    if (onBlur) _passwordTouched = true;
    if (_passwordTouched) {
      setState(
        () => _passwordError = validateSignupPasswordField(_password.text),
      );
    }
    if (_confirmTouched) _validateSignupConfirmation();
  }

  void _validateSignupConfirmation({bool onBlur = false}) {
    if (onBlur) _confirmTouched = true;
    if (_confirmTouched) {
      setState(
        () => _confirmError = validateConfirmPasswordField(
          _password.text,
          _confirm.text,
        ),
      );
    }
  }

  void _validateSignupPin({bool onBlur = false}) {
    if (onBlur) _pinTouched = true;
    if (_pinTouched) {
      setState(
        () => _pinError = _pin.text == '6967'
            ? null
            : 'The access PIN is incorrect.',
      );
    }
  }

  Future<void> _signup() async {
    if (!_acceptedPolicies) {
      setState(() => _consentError = true);
      return;
    }

    final email = _email.text.trim();
    final phone = _phone.text.trim();
    _emailTouched = _phoneTouched = _passwordTouched = _confirmTouched =
        _pinTouched = true;
    _emailError = validateEmailField(email);
    _phoneError = validateSignupPhoneField(phone);
    _passwordError = validateSignupPasswordField(_password.text);
    _confirmError = validateConfirmPasswordField(_password.text, _confirm.text);
    _pinError = _pin.text == '6967' ? null : 'The access PIN is incorrect.';
    if (_emailError != null ||
        _phoneError != null ||
        _passwordError != null ||
        _confirmError != null ||
        _pinError != null) {
      setState(() {});
      if (_pinError != null) {
        _pin.clear();
      }
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await _emailOtpCodeService.sendCode(email);
      if (!sent) {
        setState(
          () => _error =
              _emailOtpCodeService.lastError ?? 'Could not send the OTP.',
        );
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
              acceptedPolicies: _acceptedPolicies,
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
    title: 'Create your account',
    subtitle: 'Set up secure access to Hydrodeck',
    error: _error,
    busy: _busy,
    fields: [
      _field(
        _email,
        'Email',
        Icons.email_outlined,
        keyboard: TextInputType.emailAddress,
        hintText: 'example@gmail.com',
        focusNode: _emailFocus,
        errorText: _emailError,
        onChanged: (_) => _validateSignupEmail(),
      ),
      _field(
        _phone,
        'Phone number',
        Icons.phone_outlined,
        keyboard: TextInputType.phone,
        maxLength: 11,
        hintText: '09XXXXXXXXX',
        focusNode: _phoneFocus,
        errorText: _phoneError,
        onChanged: (_) => _validateSignupPhone(),
      ),
      _field(
        _password,
        'Password',
        Icons.lock_outline,
        obscure: true,
        hintText: '********',
        focusNode: _passwordFocus,
        errorText: _passwordError,
        onChanged: (_) => _validateSignupPassword(),
      ),
      _field(
        _confirm,
        'Confirm password',
        Icons.lock_outline,
        obscure: true,
        hintText: '********',
        focusNode: _confirmFocus,
        errorText: _confirmError,
        onChanged: (_) => _validateSignupConfirmation(),
      ),
      _field(
        _pin,
        'Hydrodeck access PIN',
        Icons.key_outlined,
        keyboard: TextInputType.number,
        obscure: true,
        focusNode: _pinFocus,
        errorText: _pinError,
        onChanged: (_) => _validateSignupPin(),
      ),
    ],
    actionLabel: 'Sign up',
    onAction: _submitSignup,
    beforeAction: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Checkbox(
                value: _acceptedPolicies,
                activeColor: const Color(0xFF2DC867),
                onChanged: (value) => setState(() {
                  _acceptedPolicies = value ?? false;
                  _consentError = false;
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: policyConsentText(
                  onTermsTap: () => openTermsOfUse(context),
                  onPrivacyTap: () => openPrivacyPolicy(context),
                ),
              ),
            ),
          ],
        ),
        if (_consentError)
          const Padding(
            padding: EdgeInsets.only(left: 40, top: 2),
            child: Text(
              'Accept the Terms of Use and Privacy Policy to sign up.',
              style: TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
      ],
    ),
    footer: TextButton(
      onPressed: widget.onLogin,
      child: const Text('Already have an account? Log in'),
    ),
  );
}

class LoginScreen extends StatefulWidget {
  final VoidCallback onSignup;
  final ValueChanged<User> onAuthenticated;
  const LoginScreen({
    super.key,
    required this.onSignup,
    required this.onAuthenticated,
  });
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  String? _emailError;
  String? _passwordError;
  bool _emailTouched = false;
  bool _passwordTouched = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailFocus.addListener(() {
      if (!_emailFocus.hasFocus) _validateLoginEmail(onBlur: true);
    });
    _passwordFocus.addListener(() {
      if (!_passwordFocus.hasFocus) _validateLoginPassword(onBlur: true);
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  // Inline login errors are updated on blur and then kept current while editing.
  void _validateLoginEmail({bool onBlur = false}) {
    if (onBlur) _emailTouched = true;
    if (_emailTouched) {
      setState(() {
        _emailError = validateEmailField(_email.text);
        _error = null;
      });
    }
  }

  void _validateLoginPassword({bool onBlur = false}) {
    if (onBlur) _passwordTouched = true;
    if (_passwordTouched) {
      setState(() {
        _passwordError = validatePasswordField(_password.text);
        _error = null;
      });
    }
  }

  Future<void> _login() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    _emailTouched = _passwordTouched = true;
    _emailError = validateEmailField(email);
    _passwordError = validatePasswordField(password);
    if (_emailError != null || _passwordError != null) {
      setState(() => _error = null);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = result.user;
      if (user == null) {
        if (mounted) setState(() => _error = 'Login failed. Please try again.');
        return;
      }
      if (mounted) widget.onAuthenticated(user);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyLoginException(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthFormScaffold(
    title: 'Welcome back',
    subtitle: 'Log in to continue to Hydrodeck',
    error: _error,
    busy: _busy,
    fields: [
      _field(
        _email,
        'Email',
        Icons.email_outlined,
        keyboard: TextInputType.emailAddress,
        hintText: 'example@gmail.com',
        focusNode: _emailFocus,
        errorText: _emailError,
        onChanged: (_) => _validateLoginEmail(),
      ),
      _field(
        _password,
        'Password',
        Icons.lock_outline,
        obscure: true,
        hintText: '********',
        focusNode: _passwordFocus,
        errorText: _passwordError,
        onChanged: (_) => _validateLoginPassword(),
      ),
    ],
    actionLabel: 'Log in',
    onAction: _login,
    footer: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: widget.onSignup,
          child: const Text('Create a new account'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ForgotPasswordScreen(),
                    ),
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

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await _emailOtpCodeService.sendCode(email);
      if (!sent) {
        setState(
          () => _error =
              _emailOtpCodeService.lastError ?? 'Could not send the OTP.',
        );
        return;
      }
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                OtpVerificationScreen(email: email, flow: 'forgot'),
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
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
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

abstract interface class OtpCodeService {
  Future<bool> sendCode(String email);
  bool verifyCode({required String email, required String code});
  bool isCodeExpired(String email);
  String? get lastError;
}

class EmailOtpCodeService implements OtpCodeService {
  static const Duration codeLifetime = Duration(minutes: 10);
  static String? _activeEmail;
  static DateTime? _expiresAt;

  @override
  String? get lastError => EmailOTP.lastError;

  @override
  Future<bool> sendCode(String email) async {
    _activeEmail = null;
    _expiresAt = null;

    final sent = await EmailOTP.sendOTP(email: email);
    if (sent) {
      _activeEmail = email;
      _expiresAt = DateTime.now().add(codeLifetime);
    }
    return sent;
  }

  @override
  bool verifyCode({required String email, required String code}) =>
      _activeEmail == email &&
      !isCodeExpired(email) &&
      EmailOTP.verifyOTP(otp: code);

  @override
  bool isCodeExpired(String email) =>
      _activeEmail == email &&
      _expiresAt != null &&
      !DateTime.now().isBefore(_expiresAt!);
}

final OtpCodeService _emailOtpCodeService = EmailOtpCodeService();

class OtpVerificationScreen extends StatefulWidget {
  final String email;
  final String flow;
  final OtpCodeService? otpService;
  final DateTime Function()? now;
  final String? phone;
  final String? password;
  final String? pin;
  final bool acceptedPolicies;
  final VoidCallback? onLogin;
  final VoidCallback? onDeleteConfirmed;

  const OtpVerificationScreen({
    super.key,
    required this.email,
    required this.flow,
    this.otpService,
    this.now,
    this.phone,
    this.password,
    this.pin,
    this.acceptedPolicies = false,
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
  Timer? _resendCountdownTimer;

  OtpCodeService get _otpService => widget.otpService ?? _emailOtpCodeService;
  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _resendAvailableAt = _now.add(const Duration(seconds: 3));
    _startResendCountdown();
  }

  @override
  void dispose() {
    _resendCountdownTimer?.cancel();
    _otpController.dispose();
    super.dispose();
  }

  bool get _canResend =>
      _resendAvailableAt == null || !_now.isBefore(_resendAvailableAt!);

  String get _resendLabel {
    if (_canResend) return 'Send another code';
    final remaining = _resendAvailableAt!.difference(_now);
    final totalSeconds = (remaining.inMilliseconds / 1000).ceil();
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    return 'Send another code in $minutes:$seconds';
  }

  void _startResendCountdown() {
    _resendCountdownTimer?.cancel();
    _resendCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {});
      if (_canResend) timer.cancel();
    });
  }

  Future<void> _resendCode() async {
    if (!_canResend) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await _otpService.sendCode(widget.email);
      if (!sent) {
        if (mounted) {
          setState(
            () => _error =
                _otpService.lastError ??
                'Could not send another code. Check your connection and try again.',
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _resendAvailableAt = _now.add(const Duration(minutes: 3));
      });
      _startResendCountdown();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('A new OTP has been sent.')));
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not send another code: $error';
        });
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
      final isValid = _otpService.verifyCode(email: widget.email, code: otp);
      if (!isValid) {
        setState(
          () => _error = _otpService.isCodeExpired(widget.email)
              ? 'The OTP has expired. Please request a new one.'
              : 'Invalid OTP. Please try again.',
        );
        return;
      }

      if (widget.flow == 'signup') {
        final password = widget.password ?? '';
        final phone = widget.phone ?? '';
        if (password.isEmpty || phone.isEmpty) {
          setState(() => _error = 'Signup data is missing. Please try again.');
          return;
        }
        if (!widget.acceptedPolicies) {
          setState(
            () => _error =
                'Accept the Terms of Use and Privacy Policy before creating an account.',
          );
          return;
        }

        final credential = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(
              email: widget.email,
              password: password,
            );

        await FirebaseDatabase.instance
            .ref('users/${credential.user!.uid}')
            .set({
              'email': widget.email,
              'phone': phone,
              'createdAt': ServerValue.timestamp,
              'termsOfUseVersion': termsOfUseVersion,
              'privacyPolicyVersion': privacyPolicyVersion,
              'policiesAcceptedAt': ServerValue.timestamp,
            });

        await FirebaseAuth.instance.signOut();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created successfully. Please log in.'),
            ),
          );
          Navigator.of(context).popUntil((route) => route.isFirst);
          if (widget.onLogin != null) widget.onLogin!();
        }
        return;
      }

      if (widget.flow == 'delete') {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) {
          setState(
            () => _error = 'You need to be signed in to delete your account.',
          );
          return;
        }

        DateTime scheduledAt;
        try {
          scheduledAt = (await getServerNow()).add(const Duration(days: 7));
        } catch (e) {
          if (mounted) {
            setState(
              () => _error =
                  'Failed to schedule account deletion. Please try again later.',
            );
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
            builder: (context) =>
                PasswordResetInstructionsScreen(email: widget.email),
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
        title: Text(
          widget.flow == 'signup' ? 'Verify Email' : 'Verify Reset OTP',
        ),
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
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(widget.email, style: const TextStyle(color: Colors.grey)),
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
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
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
                child: Text(
                  _busy
                      ? 'Verifying...'
                      : widget.flow == 'signup'
                      ? 'Verify & Create Account'
                      : 'Verify OTP',
                ),
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
              const Icon(
                Icons.mark_email_unread_outlined,
                size: 72,
                color: Color(0xFF2DC867),
              ),
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

Widget _field(
  TextEditingController controller,
  String label,
  IconData icon, {
  bool obscure = false,
  TextInputType? keyboard,
  int? maxLength,
  String? hintText,
  FocusNode? focusNode,
  String? errorText,
  ValueChanged<String>? onChanged,
}) {
  if (obscure) {
    return _PasswordVisibilityField(
      controller: controller,
      label: label,
      icon: icon,
      hintText: hintText,
      focusNode: focusNode,
      errorText: errorText,
      onChanged: onChanged,
    );
  }
  return TextField(
    controller: controller,
    keyboardType: keyboard,
    maxLength: maxLength,
    focusNode: focusNode,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      hintText: hintText,
      counterText: maxLength == null ? null : '',
      errorText: errorText,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

class _PasswordVisibilityField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hintText;
  final FocusNode? focusNode;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  const _PasswordVisibilityField({
    required this.controller,
    required this.label,
    required this.icon,
    this.hintText,
    this.focusNode,
    this.errorText,
    this.onChanged,
  });

  @override
  State<_PasswordVisibilityField> createState() =>
      _PasswordVisibilityFieldState();
}

class _PasswordVisibilityFieldState extends State<_PasswordVisibilityField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    focusNode: widget.focusNode,
    obscureText: _obscure,
    onChanged: widget.onChanged,
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: widget.hintText,
      errorText: widget.errorText,
      prefixIcon: Icon(widget.icon),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      suffixIcon: IconButton(
        tooltip: _obscure ? 'Show password' : 'Hide password',
        icon: Icon(
          _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        ),
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    ),
  );
}

class _AuthFormScaffold extends StatelessWidget {
  final String title, subtitle, actionLabel;
  final String? error;
  final bool busy;
  final List<Widget> fields;
  final VoidCallback onAction;
  final Widget footer;
  final Widget? beforeAction;
  const _AuthFormScaffold({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.error,
    required this.busy,
    required this.fields,
    required this.onAction,
    required this.footer,
    this.beforeAction,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF073B34),
    body: Stack(
      children: [
        Positioned(
          top: -90,
          right: -85,
          child: _HydrodeckSplash._splashCloud(240, 150),
        ),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Column(
                        children: [
                          Image.asset(
                            'hydrodeck_logo.png',
                            width: 68,
                            height: 68,
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'HYDRODECK',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2.5,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            subtitle,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFB7D7D1),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B302D),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: const Color(0x337DE6D2)),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x44000000),
                              blurRadius: 24,
                              offset: Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 18),
                            ...fields.expand(
                              (field) => [field, const SizedBox(height: 12)],
                            ),
                            if (error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  error!,
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ),
                            if (beforeAction != null) ...[
                              const SizedBox(height: 8),
                              DefaultTextStyle(
                                style: const TextStyle(color: Colors.white70),
                                child: beforeAction!,
                              ),
                            ],
                            const SizedBox(height: 12),
                            ElevatedButton(
                              onPressed: busy ? null : onAction,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2DC867),
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(52),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: busy
                                  ? const SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(actionLabel),
                            ),
                            Center(
                              child: DefaultTextStyle(
                                style: const TextStyle(color: Colors.white70),
                                child: footer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
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
      setState(
        () => _message = 'You need to be signed in to update your profile.',
      );
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
      setState(
        () => _message = 'Phone number must be 11 digits and start with 09.',
      );
      return;
    }

    if ((newPassword.isNotEmpty || confirmPassword.isNotEmpty) &&
        newPassword.length < 6) {
      setState(() => _message = 'New password must be at least 6 characters.');
      return;
    }

    if (newPassword != confirmPassword) {
      setState(
        () => _message = 'New password and confirm password must match.',
      );
      return;
    }

    if ((email != user.email || newPassword.isNotEmpty) &&
        _currentPasswordController.text.trim().isEmpty) {
      setState(
        () => _message =
            'Enter your current password to update email or password.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });
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
        setState(
          () => _message = e.message ?? 'Could not update your profile.',
        );
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
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
      setState(
        () => _message = 'You need to be signed in to delete your account.',
      );
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final sent = await _emailOtpCodeService.sendCode(user.email!);
      if (!sent) {
        throw Exception(
          _emailOtpCodeService.lastError ??
              'Could not send the confirmation email.',
        );
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
                  const SnackBar(
                    content: Text(
                      'Account deletion scheduled. You can still use the app until the 7-day period ends.',
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Could not send the confirmation email. Please try again.',
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
              _PasswordVisibilityField(
                controller: _currentPasswordController,
                label: 'Current password',
                icon: Icons.lock_outline,
              ),
              const SizedBox(height: 16),
              _PasswordVisibilityField(
                controller: _newPasswordController,
                label: 'New password',
                icon: Icons.lock_reset_outlined,
              ),
              const SizedBox(height: 16),
              _PasswordVisibilityField(
                controller: _confirmPasswordController,
                label: 'Confirm new password',
                icon: Icons.lock_reset_outlined,
              ),
              const SizedBox(height: 24),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _message!,
                    style: TextStyle(
                      color: _message!.contains('success')
                          ? Colors.green
                          : Colors.red,
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
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
  final ReservoirReading reservoir;
  final String? intervalKey;
  final String recordType;
  final String? recordId;
  final String source;

  HistoricalData({
    required this.timestamp,
    required this.pH,
    required this.temperature,
    required this.waterLevel,
    required this.tds,
    this.batchNumber,
    this.bed1,
    this.bed2,
    this.reservoir = const ReservoirReading(),
    this.intervalKey,
    this.recordType = scheduledSnapshotRecordType,
    this.recordId,
    this.source = 'app',
  });

  String get identity {
    if (recordId != null && recordId!.isNotEmpty) return recordId!;
    if (batchNumber != null && intervalKey != null) {
      return historyIdentity(
        batchNumber: batchNumber!,
        recordType: recordType,
        intervalOrEventKey: intervalKey!,
      );
    }
    return '${batchNumber ?? 0}|${timestamp.toUtc().millisecondsSinceEpoch}';
  }

  bool get readingsComplete => bed1 != null && bed2 != null;

  Map<String, dynamic> toCloudMap() => {
    'sampleTime': Timestamp.fromDate(timestamp.toUtc()),
    'batchNumber': batchNumber,
    'intervalKey': intervalKey,
    'recordType': recordType,
    'recordId': identity,
    'source': source,
    'readingsComplete': readingsComplete,
    'pH': pH,
    'temperature': temperature,
    'waterLevel': waterLevel,
    'tds': tds,
    'bed1': bed1?.toMap(),
    'bed2': bed2?.toMap(),
    'reservoir': reservoir.toMap(),
  };
}

class PhAlert {
  final String alertId;
  final double ph;
  final DateTime createdAt;
  final bool isRead;

  const PhAlert({
    required this.alertId,
    required this.ph,
    required this.createdAt,
    required this.isRead,
  });

  factory PhAlert.fromRow(Map<String, Object?> row) => PhAlert(
    alertId: row['alertId'] as String,
    ph: (row['pH'] as num).toDouble(),
    createdAt: DateTime.parse(row['createdAt'] as String).toLocal(),
    isRead: row['isRead'] == 1,
  );
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

  const ActivePlantingSession({
    required this.batchNumber,
    required this.startDate,
  });
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

String historyLogIdentity(HistoricalData log) => log.identity;

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
        final activeDocument = await activeDocumentFuture.timeout(
          const Duration(seconds: 4),
        );
        activeStateKnown = activeDocument.exists;
        final activeData = activeDocument.data();
        if (activeData?['active'] == true) {
          final batch = (activeData?['batchNumber'] as num?)?.toInt();
          final start = _parseFirebaseTimestamp(
            activeData?['startedAt'] ?? activeData?['startDate'],
          );
          if (batch != null && start != null) {
            activeSession = ActivePlantingSession(
              batchNumber: batch,
              startDate: start,
            );
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
          final batch =
              (map['batchNumber'] as num?)?.toInt() ??
              int.tryParse(document.id);
          final start = _parseFirebaseTimestamp(
            map['startedAt'] ?? map['startDate'],
          );
          final end = _parseFirebaseTimestamp(map['endedAt'] ?? map['endDate']);
          final days = (map['totalDays'] as num?)?.toInt() ?? 1;
          if (batch != null &&
              start != null &&
              end != null &&
              seenRuns.add(batch)) {
            runs.add(
              PlantingRecord(
                batchNumber: batch,
                startDate: start,
                endDate: end,
                totalDays: days,
              ),
            );
          }
        }

        for (final document in snapshots[1].docs) {
          final map = document.data();
          final timestamp = _parseFirebaseTimestamp(
            map['sampleTime'] ?? map['timestamp'],
          );
          if (timestamp == null) continue;
          final batch = (map['batchNumber'] as num?)?.toInt();
          final intervalKey =
              map['intervalKey']?.toString() ??
              map['minuteKey']?.toString() ??
              legacyManilaHalfHourIntervalKey(timestamp);
          final recordId =
              map['recordId']?.toString() ??
              (batch == null
                  ? document.id
                  : scheduledSnapshotRecordId(
                      batchNumber: batch,
                      intervalKey: intervalKey,
                    ));
          final dedupeKey = recordId;
          if (!seenLogs.add(dedupeKey)) continue;
          logs.add(
            HistoricalData(
              timestamp: timestamp,
              pH: (map['pH'] as num?)?.toDouble() ?? 0,
              temperature: map['temperature']?.toString() ?? '',
              waterLevel: map['waterLevel']?.toString() ?? 'Needs water',
              tds: (map['tds'] as num?)?.toDouble() ?? 0,
              batchNumber: batch,
              bed1: _decodeBedData(map['bed1']),
              bed2: _decodeBedData(map['bed2']),
              reservoir: ReservoirReading.fromSources(
                shared: map['reservoir'],
                bed1: map['bed1'],
                bed2: map['bed2'],
              ),
              intervalKey: intervalKey,
              recordType:
                  map['recordType']?.toString() ?? scheduledSnapshotRecordType,
              recordId: recordId,
              source: map['source']?.toString() ?? 'app',
            ),
          );
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
          if (start != null &&
              end != null &&
              batch != null &&
              days != null &&
              seenRuns.add(batch)) {
            runs.add(
              PlantingRecord(
                batchNumber: batch,
                startDate: start,
                endDate: end,
                totalDays: days,
              ),
            );
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
            final logBatch = int.tryParse(
              '${map['batchNumber'] ?? batch ?? 0}',
            );
            final dedupeKey = '${logBatch ?? 0}|${timestamp.toIso8601String()}';
            if (!seenLogs.add(dedupeKey)) continue;
            logs.add(
              HistoricalData(
                timestamp: timestamp,
                pH: double.tryParse('${map['pH'] ?? 0}') ?? 0,
                temperature: '${map['temperature'] ?? ''}',
                waterLevel: '${map['waterLevel'] ?? 'Needs water'}',
                tds: double.tryParse('${map['tds'] ?? 0}') ?? 0,
                batchNumber: logBatch,
                bed1: _decodeBedData(map['bed1']),
                bed2: _decodeBedData(map['bed2']),
                reservoir: ReservoirReading.fromSources(
                  shared: map['reservoir'],
                  bed1: map['bed1'],
                  bed2: map['bed2'],
                ),
              ),
            );
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

bool _historyUploadInFlight = false;
bool _historyCaptureInFlight = false;

HistoricalData buildScheduledSnapshot({
  required int batchNumber,
  required DateTime at,
  required GrowBedReading bed1,
  required GrowBedReading bed2,
  ReservoirReading reservoir = const ReservoirReading(),
  String source = 'app',
}) {
  final intervalKey = manilaIntervalKey(at);
  final boundary = manilaIntervalStartUtc(at);
  return HistoricalData(
    timestamp: boundary,
    pH: bed2.ph,
    temperature: '${bed2.temperature.toStringAsFixed(1)}°C',
    waterLevel: bed2.waterFull ? 'Water full' : 'Needs water',
    tds: bed2.tds,
    batchNumber: batchNumber,
    bed1: bed1,
    bed2: bed2,
    reservoir: reservoir,
    intervalKey: intervalKey,
    recordType: scheduledSnapshotRecordType,
    recordId: scheduledSnapshotRecordId(
      batchNumber: batchNumber,
      intervalKey: intervalKey,
    ),
    source: source,
  );
}

Future<bool> uploadHistoricalLog(HistoricalData snapshot) async {
  if (FirebaseAuth.instance.currentUser == null) return false;
  final batchNumber = snapshot.batchNumber;
  final intervalKey =
      snapshot.intervalKey ?? manilaIntervalKey(snapshot.timestamp);
  if (batchNumber == null) return false;
  final documentId = firestoreScheduledDocumentId(
    batchNumber: batchNumber,
    intervalKey: intervalKey,
  );
  final minuteDoc = FirebaseFirestore.instance
      .collection('hydrodeckSystems')
      .doc(_sharedHydrodeckSystemId)
      .collection('minuteLogs')
      .doc(documentId);
  try {
    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final existing = await transaction.get(minuteDoc);
      final incoming = {
        ...snapshot.toCloudMap(),
        'systemId': _sharedHydrodeckSystemId,
        'minuteKey': intervalKey,
        'timestamp': FieldValue.serverTimestamp(),
      };
      if (!existing.exists) {
        transaction.set(minuteDoc, incoming);
        return;
      }
      if (shouldReplaceHistoryRecord(
        existing: existing.data() ?? const {},
        incoming: incoming,
      )) {
        transaction.set(minuteDoc, incoming, SetOptions(merge: true));
      }
    });
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> uploadNextUnsyncedRecord() async {
  if (_historyUploadInFlight) return;
  _historyUploadInFlight = true;
  try {
    for (var i = 0; i < 8; i++) {
      final log = await DatabaseHelper.instance.getNextUnsyncedLog();
      if (log != null) {
        final uploaded = await uploadHistoricalLog(log);
        if (!uploaded) return;
        await DatabaseHelper.instance.markLogCloudSynced(log);
        continue;
      }

      final run = await DatabaseHelper.instance.getNextUnsyncedPlantingRecord();
      if (run != null) {
        final uploaded = await uploadPlantingRecord(run);
        if (!uploaded) return;
        await DatabaseHelper.instance.markPlantingRecordCloudSynced(
          run.batchNumber,
        );
        continue;
      }
      return;
    }
  } finally {
    _historyUploadInFlight = false;
  }
}

Future<HistoricalData?> _readAuthoritativeEsp32Snapshot(
  String intervalKey,
  int batchNumber,
) async {
  try {
    final snapshot = await hydrodeckDatabase()
        .ref('hydrodeck/intervalSnapshots/$intervalKey/sessions/$batchNumber')
        .get()
        .timeout(const Duration(seconds: 3));
    if (!snapshot.exists || snapshot.value is! Map) return null;
    final map = Map<String, dynamic>.from(snapshot.value as Map);
    final bed1 = _decodeBedData(map['bed1']);
    final bed2 = _decodeBedData(map['bed2']);
    if (bed1 == null || bed2 == null) return null;
    return buildScheduledSnapshot(
      batchNumber: (map['batchNumber'] as num?)?.toInt() ?? batchNumber,
      at: utcFromManilaIntervalKey(intervalKey) ?? DateTime.now().toUtc(),
      bed1: bed1,
      bed2: bed2,
      reservoir: ReservoirReading.fromSources(
        shared: map['reservoir'],
        bed1: map['bed1'],
        bed2: map['bed2'],
      ),
      source: 'esp32',
    );
  } catch (_) {
    return null;
  }
}

Future<bool> captureDueScheduledSnapshot({
  required int? batchNumber,
  required DateTime now,
}) async {
  if (batchNumber == null) return false;
  if (_historyCaptureInFlight) return false;
  _historyCaptureInFlight = true;
  try {
    final intervalKey = manilaIntervalKey(now);
    final intervalIdentity = '$batchNumber|$intervalKey';
    if (await DatabaseHelper.instance.getLastCapturedIntervalKey() ==
        intervalIdentity) {
      return false;
    }
    final authoritative = await _readAuthoritativeEsp32Snapshot(
      intervalKey,
      batchNumber,
    );
    if (authoritative == null) return false;
    if (authoritative.batchNumber == batchNumber) {
      await DatabaseHelper.instance.insertLogIfMissing(authoritative);
      await DatabaseHelper.instance.saveLastCapturedIntervalKey(
        intervalIdentity,
      );
      unawaited(uploadNextUnsyncedRecord());
      return true;
    }
    return false;
  } finally {
    _historyCaptureInFlight = false;
  }
}

Future<void> publishActiveBatchNumber(int? batchNumber) async {
  try {
    await hydrodeckDatabase()
        .ref('hydrodeck/settings/activeBatchNumber')
        .set(batchNumber ?? 0);
  } catch (_) {}
}

Future<bool> hasPendingCloudRecords() async {
  if (await DatabaseHelper.instance.getNextUnsyncedPlantingRecord() != null) {
    return true;
  }
  return await DatabaseHelper.instance.getNextUnsyncedLog() != null;
}

Future<void> syncLegacyActivePlantingSession(
  ActivePlantingSession session,
) async {
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
      final stored =
          (counterSnapshot.data()?['lastBatchNumber'] as num?)?.toInt() ?? 0;
      transaction.set(counterRef, {
        'lastBatchNumber': stored < session.batchNumber
            ? session.batchNumber
            : stored,
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
    return await FirebaseFirestore.instance.runTransaction<
      ActivePlantingSession
    >((transaction) async {
      final activeSnapshot = await transaction.get(activeRef);
      final activeData = activeSnapshot.data();
      if (activeData?['active'] == true) {
        final existingBatch = (activeData?['batchNumber'] as num?)?.toInt();
        final existingStart = _parseFirebaseTimestamp(
          activeData?['startedAt'] ?? activeData?['startDate'],
        );
        if (existingBatch != null && existingStart != null) {
          return ActivePlantingSession(
            batchNumber: existingBatch,
            startDate: existingStart,
          );
        }
      }

      final counterSnapshot = await transaction.get(counterRef);
      final stored =
          (counterSnapshot.data()?['lastBatchNumber'] as num?)?.toInt() ?? 0;
      final batchNumber = stored >= fallbackNumber
          ? stored + 1
          : fallbackNumber;
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
        (active.data()?['batchNumber'] as num?)?.toInt() ==
            record.batchNumber) {
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
        bool canCheck =
            await _localAuth.canCheckBiometrics ||
            await _localAuth.isDeviceSupported();
        if (!canCheck) {
          setState(() {
            _errorMessage =
                "Biometrics are not supported or available on this device.";
            _enableBiometrics = false;
          });
          return;
        }

        bool authenticated = await _localAuth.authenticate(
          localizedReason:
              'Please authenticate to enable biometric login for Hydrodeck',
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
                !_isPinVerified
                    ? 'Initial Setup Authorization'
                    : 'Preferences Setup',
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
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
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.lock_outline,
                        size: 48,
                        color: Color(0xFF2DC867),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Enter 4-Digit Manual PIN',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
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
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        maxLength: 4,
                        obscureText: true,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          letterSpacing: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          counterText: "",
                          hintText: "••••",
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFF2DC867),
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                      if (_lockoutTimeRemaining > 0) ...[
                        const SizedBox(height: 12),
                        Text(
                          "Locked out. Retry in $_lockoutTimeRemaining seconds.",
                          style: const TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _lockoutTimeRemaining > 0
                            ? null
                            : _verifyPin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2DC867),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(25),
                          ),
                        ),
                        child: const Text(
                          'Verify PIN',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
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
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(
                        child: Icon(
                          Icons.phonelink_setup_rounded,
                          size: 48,
                          color: Color(0xFF2DC867),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Center(
                        child: Text(
                          'Personalize Access',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Device Custom PIN (Optional)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
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
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        maxLength: 4,
                        obscureText: true,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          letterSpacing: 8,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          counterText: "",
                          hintText: "New PIN",
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFF2DC867),
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Divider(),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        activeThumbColor: const Color(0xFF2DC867),
                        title: const Text(
                          'Enable Biometrics',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'Use Fingerprint or Face ID for fast unlocking',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        value: _enableBiometrics,
                        onChanged: _handleBiometricToggle,
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
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
                        child: const Text(
                          'Save & Continue',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
                  const Icon(
                    Icons.security,
                    size: 64,
                    color: Color(0xFF2DC867),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'HYDRODECK LOCKED',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Enter your PIN to open the application',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _pinController,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    obscureText: true,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      letterSpacing: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: InputDecoration(
                      counterText: "",
                      hintText: "••••",
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: Color(0xFF2DC867),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _verifyPin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2DC867),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(25),
                      ),
                    ),
                    child: const Text(
                      'Unlock',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  if (bioEnabled) ...[
                    const SizedBox(height: 16),
                    IconButton(
                      iconSize: 40,
                      icon: const Icon(
                        Icons.fingerprint,
                        color: Color(0xFF2DC867),
                      ),
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

  final PlantingNavigationState _plantingNavigation = PlantingNavigationState();
  ActivePlantingSession? _activePlantingSession;
  List<PlantingRecord> _pastPlantingRuns = [];

  String _activeEsp32Ip = "hydrodeck.local";
  StreamSubscription? _bgSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _activePlantingSubscription;

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
    final localActiveBatch = await DatabaseHelper.instance
        .getActiveBatchNumber();
    final localRuns = await DatabaseHelper.instance.getPlantingHistory();
    final cloudHistory = await downloadCloudHistory();
    final pastRuns = <PlantingRecord>[...localRuns];
    final knownBatches = pastRuns.map((run) => run.batchNumber).toSet();
    for (final run in cloudHistory.runs) {
      if (knownBatches.add(run.batchNumber)) {
        pastRuns.add(run);
        await DatabaseHelper.instance.insertPlantingRecord(
          run,
          cloudSynced: true,
        );
      }
    }
    final localLogs = await DatabaseHelper.instance.getLogs();
    final knownLogKeys = localLogs.map(historyLogIdentity).toSet();
    for (final log in cloudHistory.logs) {
      final key = historyLogIdentity(log);
      if (knownLogKeys.add(key)) {
        await DatabaseHelper.instance.insertLogIfMissing(
          log,
          cloudSynced: true,
        );
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
        batchNumber:
            localActiveBatch ??
            (pastRuns.isEmpty ? 1 : pastRuns.last.batchNumber + 1),
        startDate: localActiveDate,
      );
      unawaited(syncLegacyActivePlantingSession(activeSession));
    }

    final savedIp = await DatabaseHelper.instance.getActiveIp();
    if (mounted) {
      setState(() {
        _pastPlantingRuns = pastRuns
          ..sort((a, b) => a.batchNumber.compareTo(b.batchNumber));
        _activeEsp32Ip = savedIp;
        _activePlantingSession = activeSession;
        _isLoading = false;
      });
    }
    if (activeSession != null) {
      await publishActiveBatchNumber(activeSession.batchNumber);
    }
    final hasPendingRecords = await hasPendingCloudRecords();
    if ((activeSession != null || hasPendingRecords) &&
        _supportsBackgroundService) {
      await initializeBackgroundService();
      FlutterBackgroundService().invoke('setPlantingState', {
        'active': activeSession != null,
      });
    }
    _subscribeToActivePlanting();
  }

  void _listenToBackgroundService() {
    if (!_supportsBackgroundService) return;
    try {
      _bgSubscription = FlutterBackgroundService().on('telemetryUpdate').listen(
        (event) {
          if (event != null && event['ip'] != null && mounted) {
            setState(() {
              _activeEsp32Ip = event['ip'];
            });
          }
        },
      );
    } catch (_) {}
  }

  void _subscribeToActivePlanting() {
    try {
      final activeRef = FirebaseFirestore.instance
          .collection('hydrodeckSystems')
          .doc(_sharedHydrodeckSystemId)
          .collection('metadata')
          .doc('activePlanting');
      _activePlantingSubscription = activeRef.snapshots().listen((
        snapshot,
      ) async {
        final data = snapshot.data();
        if (data == null) return;
        final batch = (data['batchNumber'] as num?)?.toInt();
        final start = _parseFirebaseTimestamp(
          data['startedAt'] ?? data['startDate'],
        );
        if (data['active'] == true && batch != null && start != null) {
          await DatabaseHelper.instance.saveActiveSession(start, batch);
          unawaited(publishActiveBatchNumber(batch));
          if (!mounted) return;
          final isNewSession = _activePlantingSession?.batchNumber != batch;
          setState(() {
            _activePlantingSession = ActivePlantingSession(
              batchNumber: batch,
              startDate: start,
            );
          });
          if (isNewSession && _supportsBackgroundService) {
            await initializeBackgroundService();
            FlutterBackgroundService().invoke('setPlantingState', {
              'active': true,
            });
          }
          return;
        }

        final end = _parseFirebaseTimestamp(data['endedAt']);
        if (batch != null && start != null) {
          if (end != null) {
            final record = PlantingRecord(
              batchNumber: batch,
              startDate: start,
              endDate: end,
              totalDays: (data['totalDays'] as num?)?.toInt() ?? 1,
            );
            if (!_pastPlantingRuns.any((run) => run.batchNumber == batch)) {
              await DatabaseHelper.instance.insertPlantingRecord(
                record,
                cloudSynced: true,
              );
              if (mounted) setState(() => _pastPlantingRuns.add(record));
            }
          }
        }

        if (batch == _activePlantingSession?.batchNumber && end != null) {
          await DatabaseHelper.instance.clearActiveSession();
          if (!mounted) return;
          setState(() {
            _activePlantingSession = null;
            _plantingNavigation.showStartContinue();
          });
          if (_supportsBackgroundService) {
            FlutterBackgroundService().invoke('setPlantingState', {
              'active': false,
            });
          }
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  void _startPlanting() async {
    final now = await getServerNow();
    final localCandidate =
        _pastPlantingRuns.fold<int>(
          0,
          (maximum, run) =>
              run.batchNumber > maximum ? run.batchNumber : maximum,
        ) +
        1;
    final activeSession = await startOrResumePlanting(now, localCandidate);
    await DatabaseHelper.instance.saveActiveSession(
      activeSession.startDate,
      activeSession.batchNumber,
    );
    await publishActiveBatchNumber(activeSession.batchNumber);

    if (_supportsBackgroundService) {
      await initializeBackgroundService();
      FlutterBackgroundService().invoke('setPlantingState', {'active': true});
    }

    setState(() {
      _activePlantingSession = activeSession;
      _plantingNavigation.showDashboard();
    });
  }

  void _endPlanting() async {
    final activeSession = _activePlantingSession;
    if (activeSession == null) return;

    final now = await getServerNow();
    int totalDays = (now.difference(activeSession.startDate).inDays + 1).clamp(
      1,
      999999,
    );

    final batchNumber = activeSession.batchNumber;
    final newRecord = PlantingRecord(
      batchNumber: batchNumber,
      startDate: activeSession.startDate,
      endDate: now,
      totalDays: totalDays,
    );

    await DatabaseHelper.instance.insertPlantingRecord(newRecord);
    await DatabaseHelper.instance.clearActiveSession();
    await publishActiveBatchNumber(null);
    unawaited(
      uploadPlantingRecord(newRecord)
          .then((uploaded) async {
            if (uploaded) {
              await DatabaseHelper.instance.markPlantingRecordCloudSynced(
                newRecord.batchNumber,
              );
            }
          })
          .catchError((_) {}),
    );
    if (_supportsBackgroundService) {
      FlutterBackgroundService().invoke('setPlantingState', {'active': false});
    }

    setState(() {
      _pastPlantingRuns.add(newRecord);
      _activePlantingSession = null;
      _plantingNavigation.showStartContinue();
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

    final activeSession = _activePlantingSession;
    if (_plantingNavigation.page == PlantingNavigationPage.startContinue) {
      return StartPlantingScreen(
        onStart: _startPlanting,
        onContinue: _startPlanting,
        activeSession: activeSession,
        history: _pastPlantingRuns,
      );
    }
    return HydroponicsDashboard(
      startDate: activeSession!.startDate,
      batchNumber: activeSession.batchNumber,
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
                                child: Icon(
                                  Icons.eco,
                                  color: Color(0xFF2DC867),
                                ),
                              ),
                              title: Text(
                                'Batch #${run.batchNumber}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
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
                                    builder: (context) =>
                                        BatchHistoryScreen(record: run),
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
                      ),
                    ],
                  ),
                  child: Center(
                    child: Image.asset(
                      'hydrodeck_logo.png',
                      width: 112,
                      height: 112,
                      fit: BoxFit.contain,
                      semanticLabel: 'HydroDeck logo',
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
                    activeSession == null
                        ? 'Start Planting'
                        : 'Continue Planting',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => _showHistoryDialog(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF2DC867),
                    side: const BorderSide(
                      color: Color(0xFF2DC867),
                      width: 1.5,
                    ),
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

class _HydroponicsDashboardState extends State<HydroponicsDashboard>
    with WidgetsBindingObserver {
  static const String _esp32Hotspot = 'ESP32-HYDRODECK';
  static const String _esp32HotspotPassword = 'hydrodeck';

  int _currentIndex = 0;
  int _unreadPhAlertCount = 0;
  Timer? _unreadAlertTimer;

  late String _esp32Ip;

  String _connectionStatus = "ESP32 offline";

  GrowBedReading _bed1 = GrowBedReading.empty();
  GrowBedReading _bed2 = GrowBedReading.empty();
  ReservoirReading _reservoir = const ReservoirReading();
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
  StreamSubscription? _firebaseConnectionSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _cloudLogsSub;
  StreamSubscription?
  _firebaseCommandsSub; // Subscription for command status updates
  Timer? _connectionTimer;
  bool _wifiPromptShown = false;
  bool _offlinePromptShown = false;
  bool _offlineBannerDismissed = false;
  bool? _firebaseConnected;
  bool _wifiProvisioningCompleted = false;
  bool _isRefreshingConnectivity = false;
  bool _connectivityProbeInProgress = false;
  bool _historyReconcileInFlight = false;
  DateTime? _lastHistoryReconcileAt;
  DateTime? _lastLocalTelemetryAt;
  DateTime? _lastFirebaseTelemetryAt;
  Timer? _thresholdPublishTimer;
  DateTime? _offlineSince;
  List<String> _discoveredHotspots = [];
  final Map<String, bool> _actuatorBusy = {};
  final Map<String, bool> _pendingActuatorStates = {};
  // Track pending command requests to prevent duplicates and enable acknowledgment
  final Map<String, String> _pendingCommandIds =
      {}; // actuatorName -> commandId
  final Map<String, Timer> _commandTimeouts = {};
  final Set<String> _commandsAcceptedOrRunning = {};
  final Set<String> _actuatorsSeenRunning = {};
  final Map<String, Timer> _actuatorTelemetryTimeouts = {};
  bool? _confirmedGrowLightState;

  List<HistoricalData> _historyLogs = [];
  DateTime? _selectedFilterDate;

  late TextEditingController _wifiSsidController;
  late TextEditingController _wifiPasswordController;
  final HotspotAttemptGate _hotspotAttemptGate = HotspotAttemptGate();
  bool get _isHotspotConnecting => _hotspotAttemptGate.isActive;
  String _hotspotStatus = 'ESP32 hotspot not connected';

  double _minPhThreshold = 5.5;
  double _maxPhThreshold = 7.0;
  bool _hasSharedPhThresholds = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _esp32Ip = widget.initialIp;
    _wifiSsidController = TextEditingController();
    _wifiPasswordController = TextEditingController();
    _loadStoredLogsAndSettings();
    unawaited(_refreshUnreadPhAlertCount());
    _unreadAlertTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshUnreadPhAlertCount()),
    );
    unawaited(_reconcileHistory());
    unawaited(_subscribeToCloudLogs());
    _subscribeToFirebaseConnection();
    _subscribeToFirebase();
    _subscribeToBackgroundUpdates();
    _subscribeToFirebaseCommands();
    unawaited(_refreshServerTime());

    _offlineSince = DateTime.now();
    unawaited(_refreshConnectivity(showLoading: false));

    _connectionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) {
        unawaited(_refreshConnectivity(showLoading: false));
        setState(_updateConnectionStatus);
        if (_firebaseConnected == true) {
          _offlinePromptShown = false;
          _offlineBannerDismissed = false;
          if (_hasFreshLocalTelemetry || _hasFreshFirebaseTelemetry) {
            _offlineSince = null;
            _wifiPromptShown = false;
          } else if (!_wifiPromptShown &&
              !_wifiProvisioningCompleted &&
              shouldShowWifiSetupPrompt(
                localDeviceReachable: _hasFreshLocalTelemetry,
                cloudReachable: _hasFreshFirebaseTelemetry,
              ) &&
              _currentIndex == 0) {
            _offlineSince ??= DateTime.now();
            if (DateTime.now().difference(_offlineSince!).inSeconds >= 3) {
              _showWifiSetupDialog();
            }
          }
        } else if (_firebaseConnected == false) {
          _offlineSince ??= DateTime.now();
          if (!_offlinePromptShown &&
              shouldShowOfflineHotspotPrompt(
                firebaseConnected: _firebaseConnected,
                localDeviceReachable: _hasFreshLocalTelemetry,
              ) &&
              DateTime.now().difference(_offlineSince!).inSeconds >= 3) {
            _showOfflineHotspotDialog();
          }
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshConnectivity(showLoading: false));
      unawaited(_reconcileHistory(force: true));
    }
  }

  Future<void> _refreshUnreadPhAlertCount() async {
    try {
      final unreadCount = await DatabaseHelper.instance.getUnreadPhAlertCount();
      if (mounted && unreadCount != _unreadPhAlertCount) {
        setState(() => _unreadPhAlertCount = unreadCount);
      }
    } catch (error) {
      debugPrint('Could not refresh notification badge: $error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unreadAlertTimer?.cancel();
    _telemetrySub?.cancel();
    _snapshotSub?.cancel();
    _firebaseSub?.cancel();
    _firebaseConnectionSub?.cancel();
    _cloudLogsSub?.cancel();
    _firebaseCommandsSub?.cancel();
    _connectionTimer?.cancel();
    _thresholdPublishTimer?.cancel();
    for (final timer in _commandTimeouts.values) {
      timer.cancel();
    }

    for (final timer in _actuatorTelemetryTimeouts.values) {
      timer.cancel();
    }
    _wifiSsidController.dispose();
    _wifiPasswordController.dispose();
    super.dispose();
  }

  void _subscribeToFirebaseConnection() {
    try {
      _firebaseConnectionSub = hydrodeckDatabase()
          .ref('.info/connected')
          .onValue
          .listen(
            (event) {
              if (!mounted) return;
              final connected = event.snapshot.value == true;
              setState(() {
                _firebaseConnected = connected;
                if (connected) {
                  _offlineSince = null;
                  _offlinePromptShown = false;
                  _offlineBannerDismissed = false;
                  _wifiPromptShown = false;
                }
              });
            },
            onError: (_) {
              if (mounted) {
                setState(() => _firebaseConnected = false);
              }
            },
          );
    } catch (_) {
      // Firebase may not be initialized yet; wait for its connection event.
    }
  }

  void _subscribeToFirebase() {
    if (kIsWeb) return;

    try {
      final ref = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
      ).ref('hydrodeck');
      _firebaseSub = ref.onValue.listen(
        (event) async {
          final value = event.snapshot.value;
          if (mounted) {
            setState(_updateConnectionStatus);
          }
          if (value is! Map) return;

          final payload = Map<String, dynamic>.from(value);
          final lastSeen = payload['lastSeen'];
          final heartbeatMillis = _parseHeartbeatMillis(lastSeen);
          final heartbeatFresh = isDeviceHeartbeatFresh(heartbeatMillis);
          final telemetry = HydrodeckTelemetry.fromJson(payload);
          final settings = payload['settings'];
          double? sharedMinPh;
          double? sharedMaxPh;
          if (settings is Map) {
            final minValue = settings['minPh'];
            final maxValue = settings['maxPh'];
            if (minValue is num && maxValue is num) {
              final candidateMin = minValue.toDouble();
              final candidateMax = maxValue.toDouble();
              if (isValidPhThresholds(candidateMin, candidateMax)) {
                sharedMinPh = candidateMin;
                sharedMaxPh = candidateMax;
              }
            }
          }

          if (!mounted) return;
          final applyFirebaseDeviceState = shouldApplyFirebaseDeviceState(
            localTelemetryFresh: _hasFreshLocalTelemetry,
          );
          setState(() {
            if (heartbeatFresh) {
              _lastFirebaseTelemetryAt = DateTime.now();
            }
            if (applyFirebaseDeviceState) {
              _reservoir = telemetry.reservoir;
              if (payload.containsKey('temp1') ||
                  payload.containsKey('ph1') ||
                  payload.containsKey('tds1') ||
                  payload.containsKey('water1') ||
                  payload['bed1'] is Map) {
                _bed1 = telemetry.bed1;
              }
              if (payload.containsKey('temp2') ||
                  payload.containsKey('ph2') ||
                  payload.containsKey('tds2') ||
                  payload.containsKey('water2') ||
                  payload['bed2'] is Map) {
                _bed2 = telemetry.bed2;
              }

              final actuators = payload['actuators'] is Map
                  ? Map<String, dynamic>.from(payload['actuators'] as Map)
                  : payload;
              _updateActuatorFromFirebase(
                'bed1_water',
                'waterPump1',
                actuators,
              );
              _updateActuatorFromFirebase('bed1_ph_up', 'phUp1', actuators);
              _updateActuatorFromFirebase('bed1_ph_down', 'phDown1', actuators);
              _updateActuatorFromFirebase(
                'bed1_nutrient',
                'nutrient1',
                actuators,
              );
              _updateActuatorFromFirebase(
                'bed2_water',
                'waterPump2',
                actuators,
              );
              _updateActuatorFromFirebase('bed2_ph_up', 'phUp2', actuators);
              _updateActuatorFromFirebase('bed2_ph_down', 'phDown2', actuators);
              _updateActuatorFromFirebase(
                'bed2_nutrient',
                'nutrient2',
                actuators,
              );
              _applyGrowLightTelemetry(telemetry.growLightOn);
            }
            _updateConnectionStatus();
            if (payload['ip'] != null) {
              _esp32Ip = payload['ip'].toString();
            }
          });
          if (sharedMinPh != null && sharedMaxPh != null) {
            await _applySharedPhThresholds(sharedMinPh, sharedMaxPh);
          }
        },
        onError: (_) {
          if (mounted) setState(_updateConnectionStatus);
        },
      );
    } catch (_) {
      // Firebase is unavailable; telemetry will fall back to manual polling.
    }
  }

  Future<void> _applySharedPhThresholds(double minimum, double maximum) async {
    if (!isValidPhThresholds(minimum, maximum)) return;
    _hasSharedPhThresholds = true;
    final changed = minimum != _minPhThreshold || maximum != _maxPhThreshold;
    if (!mounted) return;
    if (changed) {
      setState(() {
        _minPhThreshold = minimum;
        _maxPhThreshold = maximum;
      });
    }
    await DatabaseHelper.instance.saveSettingsConfig(minimum, maximum);
    if (_supportsBackgroundService) {
      FlutterBackgroundService().invoke('updateLimits', {
        'minPh': minimum,
        'maxPh': maximum,
      });
    }
    if (changed) {
      unawaited(_postPhThresholdsToLocalEsp32(minimum, maximum).then((_) {}));
    }
  }

  Future<bool> _postPhThresholdsToLocalEsp32(
    double minimum,
    double maximum,
  ) async {
    if (!isValidPhThresholds(minimum, maximum)) return false;
    var posted = false;
    try {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(true);
      } catch (_) {}
      for (final target in _localControlTargets()) {
        try {
          final response = await http
              .get(
                Uri.parse(
                  'http://$target/settings?minPh=${minimum.toStringAsFixed(2)}&maxPh=${maximum.toStringAsFixed(2)}',
                ),
                headers: {'Connection': 'close'},
              )
              .timeout(const Duration(seconds: 2));
          if (response.statusCode == 200) {
            posted = true;
            return true;
          }
        } catch (_) {}
      }
    } finally {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      } catch (_) {}
    }
    return posted;
  }

  void _subscribeToFirebaseCommands() {
    if (kIsWeb) return;
    try {
      final acknowledgmentsRef = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
      ).ref('hydrodeck/commandAcks');
      _firebaseCommandsSub = acknowledgmentsRef.onValue.listen((event) {
        if (!mounted) return;
        final value = event.snapshot.value;
        if (value is! Map) return;
        final acknowledgments = Map<String, dynamic>.from(value);
        var changed = false;
        for (final pending in _pendingCommandIds.entries.toList()) {
          final status = acknowledgments[pending.value]?.toString();
          if (isConfirmedWaterPumpOnAck(pending.key, status)) {
            final busyKey = _getActuatorBusyKey(pending.key);
            _pendingCommandIds.remove(pending.key);
            _commandsAcceptedOrRunning.remove(pending.value);
            _commandTimeouts.remove(pending.value)?.cancel();
            unawaited(_removeFirebaseCommandRecord(pending.key, pending.value));
            if (busyKey != null) {
              _controlStates[busyKey] = true;
              _actuatorBusy[busyKey] = false;
              _pendingActuatorStates.remove(busyKey);
              _actuatorsSeenRunning.remove(busyKey);
            }
            changed = true;
            continue;
          }
          if (status == 'accepted' || status == 'running') {
            final firstAcceptance = _commandsAcceptedOrRunning.add(
              pending.value,
            );
            final busyKey = _getActuatorBusyKey(pending.key);
            if (busyKey != null) _actuatorBusy[busyKey] = true;
            if (pending.key.startsWith('waterPump')) {
              if (firstAcceptance) {
                _commandTimeouts.remove(pending.value)?.cancel();
                _commandTimeouts[pending.value] = Timer(commandAckTimeout, () {
                  if (_pendingCommandIds[pending.key] != pending.value) return;
                  _clearPendingCommand(pending.key, pending.value);
                  unawaited(
                    _removeFirebaseCommandRecord(pending.key, pending.value),
                  );
                  if (mounted) {
                    _showCommandMessage(
                      pending.key,
                      friendlyCommandFailureMessage(status: 'unconfirmed'),
                    );
                    setState(() {});
                  }
                });
              }
            } else {
              _commandTimeouts.remove(pending.value)?.cancel();
              _commandTimeouts[pending.value] = Timer(
                _actuatorPulseGrace(pending.key),
                () {
                  if (_pendingCommandIds[pending.key] != pending.value) return;
                  _clearPendingCommand(pending.key, pending.value);
                  if (mounted) {
                    _showCommandMessage(
                      pending.key,
                      friendlyCommandFailureMessage(status: 'unconfirmed'),
                    );
                    setState(() {});
                  }
                },
              );
            }
            changed = true;
            continue;
          }
          if (!shouldReleasePendingCommand(status: status)) continue;
          _commandsAcceptedOrRunning.remove(pending.value);
          _pendingCommandIds.remove(pending.key);
          _commandTimeouts.remove(pending.value)?.cancel();
          unawaited(_removeFirebaseCommandRecord(pending.key, pending.value));
          final busyKey = _getActuatorBusyKey(pending.key);
          if (busyKey != null) _actuatorsSeenRunning.remove(busyKey);
          if (busyKey != null) {
            if (pending.key.startsWith('waterPump') && status == 'completed') {
              _controlStates[busyKey] =
                  _pendingActuatorStates[busyKey] ?? false;
            } else if (pending.key.startsWith('waterPump') &&
                status == 'timed_out') {
              _controlStates[busyKey] = false;
            }
            if (pending.key == 'growLight') {
              final requestedState = _pendingActuatorStates[busyKey];
              if (status == 'completed' && requestedState != null) {
                _controlStates[busyKey] = requestedState;
                _confirmedGrowLightState = requestedState;
              } else {
                _confirmedGrowLightState = null;
              }
            }
            _actuatorBusy[busyKey] = false;
            _pendingActuatorStates.remove(busyKey);
          }
          if (status == 'rejected') {
            unawaited(_showCommandRejection(pending.key, pending.value));
          } else if (status == 'timed_out') {
            _showCommandMessage(
              pending.key,
              friendlyCommandFailureMessage(status: 'timed_out'),
            );
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

  String _friendlyCommandRejection(String reason) =>
      friendlyCommandFailureMessage(status: 'rejected', reason: reason);

  Future<void> _showCommandRejection(
    String actuatorName,
    String commandId, {
    String fallback = 'The ESP32 rejected this command.',
  }) async {
    var reason = '';
    for (var attempt = 0; attempt < 3 && reason.isEmpty; attempt++) {
      try {
        final snapshot = await hydrodeckDatabase()
            .ref('hydrodeck/commandAckReasons/$commandId')
            .get()
            .timeout(const Duration(seconds: 1));
        reason = snapshot.value?.toString() ?? '';
      } catch (_) {}
      if (reason.isEmpty && attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    _showCommandMessage(
      actuatorName,
      reason.isEmpty ? fallback : _friendlyCommandRejection(reason),
    );
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

  bool get _chemicalPumpBusy {
    const chemicalActuators = [
      'phUp1',
      'phDown1',
      'nutrient1',
      'phUp2',
      'phDown2',
      'nutrient2',
    ];
    return chemicalActuators.any((actuator) {
      final key = _actuatorControlKeys[actuator]!;
      return _actuatorBusy[key] == true ||
          _pendingCommandIds.containsKey(actuator);
    });
  }

  void _updateActuatorStates(Map<String, bool> states, {bool isLocal = false}) {
    for (final entry in states.entries) {
      final key = _actuatorControlKeys[entry.key];
      if (key != null) {
        _updateActuatorFromFirebase(key, entry.key, {
          entry.key: entry.value,
        }, isLocal: isLocal);
      }
    }
  }

  void _updateActuatorFromFirebase(
    String key,
    String actuatorName,
    Map<String, dynamic> actuators, {
    bool isLocal = false,
  }) {
    if (!actuators.containsKey(actuatorName)) return;
    final value = HydrodeckTelemetry._readBoolLike(actuators, [actuatorName]);
    if (actuatorName == 'growLight') {
      _applyGrowLightTelemetry(value);
      _actuatorBusy[key] = _pendingCommandIds.containsKey(actuatorName);
      return;
    }
    final pendingId = _pendingCommandIds[actuatorName];
    final isWaterPump = actuatorName.startsWith('waterPump');
    if (pendingId != null) {
      if (isWaterPump) _controlStates[key] = value;
      final requestedState = _pendingActuatorStates[key];
      if (isLocal &&
          isWaterPump &&
          requestedState != null &&
          reportedActuatorStateConfirmsRequest(
            requestedState: requestedState,
            reportedState: value,
          )) {
        _clearPendingCommand(actuatorName, pendingId);
        _actuatorBusy[key] = value;
        return;
      }
      if (value) {
        if (_actuatorsSeenRunning.add(key)) {
          _commandsAcceptedOrRunning.add(pendingId);
          _commandTimeouts.remove(pendingId)?.cancel();
          _actuatorBusy[key] = true;
          if (!isWaterPump) {
            _commandTimeouts[pendingId] = Timer(
              _actuatorPulseGrace(actuatorName),
              () {
                if (_pendingCommandIds[actuatorName] != pendingId) return;
                _clearPendingCommand(actuatorName, pendingId);
                if (mounted) setState(() {});
              },
            );
          }
        }
      } else if (isWaterPump && _pendingActuatorStates[key] == false) {
        _actuatorBusy[key] = false;
        _controlStates[key] = false;
      } else if (_actuatorsSeenRunning.remove(key)) {
        _clearPendingCommand(actuatorName, pendingId);
      } else if (isWaterPump) {
        _actuatorBusy[key] = false;
      } else {
        _actuatorBusy[key] = true;
      }
      return;
    }

    _controlStates[key] = value;
    if (isWaterPump) {
      _actuatorBusy[key] = value;
      _actuatorTelemetryTimeouts.remove(key)?.cancel();
      _actuatorsSeenRunning.remove(key);
      return;
    }
    if (value) {
      if (_actuatorsSeenRunning.add(key)) {
        _actuatorBusy[key] = true;
        _actuatorTelemetryTimeouts[key]?.cancel();
        _actuatorTelemetryTimeouts[key] = Timer(
          _actuatorPulseGrace(actuatorName),
          () {
            if (_pendingCommandIds.containsKey(actuatorName)) return;
            _actuatorBusy[key] = false;
            if (mounted) setState(() {});
          },
        );
      }
    } else {
      _actuatorsSeenRunning.remove(key);
      _actuatorTelemetryTimeouts.remove(key)?.cancel();
      _actuatorBusy[key] = false;
    }
  }

  void _applyGrowLightTelemetry(bool state) {
    final pendingState = _pendingActuatorStates['grow_light'];
    if (pendingState != null && pendingState != state) return;
    final confirmedState = _confirmedGrowLightState;
    if (confirmedState != null && confirmedState != state) return;
    _controlStates['grow_light'] = state;
    if (pendingState == state || confirmedState == state) {
      _pendingActuatorStates.remove('grow_light');
      _confirmedGrowLightState = null;
      final pendingCommandId = _pendingCommandIds['growLight'];
      if (pendingCommandId != null) {
        _clearPendingCommand('growLight', pendingCommandId);
      }
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
    if (showLoading && mounted) {
      setState(() => _isRefreshingConnectivity = true);
    }
    var localConnected = false;
    var deviceReachable = false;
    try {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(true);
      } catch (_) {}
      final targets = <String>{
        _esp32Ip.trim(),
        '192.168.4.1',
        'hydrodeck.local',
      }..remove('');
      Future<MapEntry<String, HydrodeckTelemetry>?> probe(String target) async {
        try {
          final response = await http
              .get(
                Uri.parse('http://$target/status'),
                headers: {'Connection': 'close'},
              )
              .timeout(const Duration(milliseconds: 900));
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
      for (final result
          in localResults.whereType<MapEntry<String, HydrodeckTelemetry>>()) {
        if (!mounted) return;
        setState(() {
          _bed1 = result.value.bed1;
          _bed2 = result.value.bed2;
          _reservoir = result.value.reservoir;
          _applyGrowLightTelemetry(result.value.growLightOn);
          _updateActuatorStates(result.value.actuatorStates, isLocal: true);
          _esp32Ip = result.key;
          _lastLocalTelemetryAt = DateTime.now();
        });
        localConnected = true;
        deviceReachable = true;
        if (_currentIndex == 0) break;
      }

      if (!localConnected) {
        try {
          await WiFiForIoTPlugin.forceWifiUsage(false);
        } catch (_) {}
        var freshDeviceHeartbeat = false;
        var statusData = <String, dynamic>{};
        try {
          final database = FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL:
                'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
          );
          final snapshot = await database
              .ref('hydrodeck')
              .get()
              .timeout(const Duration(seconds: 2));
          statusData = snapshot.value is Map
              ? Map<String, dynamic>.from(snapshot.value as Map)
              : <String, dynamic>{};
          final heartbeatMillis = _parseHeartbeatMillis(statusData['lastSeen']);
          freshDeviceHeartbeat = isDeviceHeartbeatFresh(heartbeatMillis);
          if (freshDeviceHeartbeat) {
            deviceReachable = true;
            _lastFirebaseTelemetryAt = DateTime.now();
          }
        } catch (_) {}
        if (mounted) {
          setState(() {
            _lastLocalTelemetryAt = null;
            if (!freshDeviceHeartbeat &&
                (_lastFirebaseTelemetryAt == null ||
                    DateTime.now()
                            .difference(_lastFirebaseTelemetryAt!)
                            .inSeconds >
                        _deviceHeartbeatGraceSeconds)) {
              _lastFirebaseTelemetryAt = null;
            }
          });
        }
      }
      if (deviceReachable) unawaited(_reconcileHistory());
    } finally {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      } catch (_) {}
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
    _connectionStatus = dashboardConnectionStatus(
      localTelemetryFresh: _hasFreshLocalTelemetry,
      firebaseHeartbeatFresh: _hasFreshFirebaseTelemetry,
    );
  }

  bool get _hasFreshLocalTelemetry =>
      _lastLocalTelemetryAt != null &&
      DateTime.now().difference(_lastLocalTelemetryAt!).inSeconds <= 10;

  bool get _hasFreshFirebaseTelemetry =>
      _lastFirebaseTelemetryAt != null &&
      DateTime.now().difference(_lastFirebaseTelemetryAt!).inSeconds <=
          _deviceHeartbeatGraceSeconds;

  bool get _hasFreshSensorTelemetry =>
      _hasFreshLocalTelemetry || _hasFreshFirebaseTelemetry;

  Future<void> _loadStoredLogsAndSettings() async {
    final activeBatchNumber =
        widget.batchNumber ??
        await DatabaseHelper.instance.getActiveBatchNumber();
    final storedLogs = activeBatchNumber == null
        ? <HistoricalData>[]
        : await DatabaseHelper.instance.getLogsForBatch(activeBatchNumber);
    final config = await DatabaseHelper.instance.getSettingsConfig();
    if (mounted) {
      setState(() {
        _historyLogs = storedLogs;
        if (storedLogs.isNotEmpty) {
          _reservoir = storedLogs.first.reservoir;
        }
        if (!_hasSharedPhThresholds) {
          _minPhThreshold = config['minPh'] ?? 5.5;
          _maxPhThreshold = config['maxPh'] ?? 7.0;
        }

        if (storedLogs.isNotEmpty) {
          _lastValidWaterStatus = storedLogs.first.waterLevel == "Water full"
              ? "full"
              : "low";
          _bed2 = GrowBedReading(
            temperature:
                double.tryParse(
                  storedLogs.first.temperature.replaceAll(
                    RegExp(r'[^0-9.\-]'),
                    '',
                  ),
                ) ??
                25.0,
            ph: storedLogs.first.pH,
            tds: storedLogs.first.tds,
            waterFull: _lastValidWaterStatus == 'full',
          );
        }
      });
    }
  }

  Future<void> _reconcileHistory({bool force = false}) async {
    if (_historyReconcileInFlight) return;
    final wallClockNow = DateTime.now();
    if (!force &&
        _lastHistoryReconcileAt != null &&
        wallClockNow.difference(_lastHistoryReconcileAt!).inSeconds < 30) {
      await uploadNextUnsyncedRecord();
      return;
    }
    _historyReconcileInFlight = true;
    _lastHistoryReconcileAt = wallClockNow;
    try {
      final serverNow = await getServerNow();
      final batchNumber =
          widget.batchNumber ??
          await DatabaseHelper.instance.getActiveBatchNumber();
      if (batchNumber != null) {
        await captureDueScheduledSnapshot(
          batchNumber: batchNumber,
          now: serverNow,
        );
      }
      await uploadNextUnsyncedRecord();
      if (batchNumber != null) {
        final storedLogs = await DatabaseHelper.instance.getLogsForBatch(
          batchNumber,
        );
        if (mounted && storedLogs.isNotEmpty) {
          setState(() {
            _historyLogs =
                mergeHistoryByIdentity([
                    ...storedLogs,
                    ..._historyLogs,
                  ], historyLogIdentity).values.toList()
                  ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
          });
        }
      }
    } finally {
      _historyReconcileInFlight = false;
    }
  }

  Future<void> _subscribeToCloudLogs() async {
    final batchNumber =
        widget.batchNumber ??
        await DatabaseHelper.instance.getActiveBatchNumber();
    if (batchNumber == null || FirebaseAuth.instance.currentUser == null) {
      return;
    }

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
              final timestamp = _parseFirebaseTimestamp(
                map['sampleTime'] ?? map['timestamp'],
              );
              if (timestamp == null) continue;
              final intervalKey =
                  map['intervalKey']?.toString() ??
                  map['minuteKey']?.toString() ??
                  legacyManilaHalfHourIntervalKey(timestamp);
              final recordId =
                  map['recordId']?.toString() ??
                  scheduledSnapshotRecordId(
                    batchNumber:
                        (map['batchNumber'] as num?)?.toInt() ?? batchNumber,
                    intervalKey: intervalKey,
                  );
              incoming.add(
                HistoricalData(
                  timestamp: timestamp,
                  pH: (map['pH'] as num?)?.toDouble() ?? 0,
                  temperature: map['temperature']?.toString() ?? '',
                  waterLevel: map['waterLevel']?.toString() ?? 'Needs water',
                  tds: (map['tds'] as num?)?.toDouble() ?? 0,
                  batchNumber:
                      (map['batchNumber'] as num?)?.toInt() ?? batchNumber,
                  bed1: _decodeBedData(map['bed1']),
                  bed2: _decodeBedData(map['bed2']),
                  reservoir: ReservoirReading.fromSources(
                    shared: map['reservoir'],
                    bed1: map['bed1'],
                    bed2: map['bed2'],
                  ),
                  intervalKey: intervalKey,
                  recordType:
                      map['recordType']?.toString() ??
                      scheduledSnapshotRecordType,
                  recordId: recordId,
                  source: map['source']?.toString() ?? 'app',
                ),
              );
            }
            for (final log in incoming) {
              await DatabaseHelper.instance.insertLogIfMissing(
                log,
                cloudSynced: true,
              );
            }
            if (!mounted || incoming.isEmpty) return;
            final storedLogs = await DatabaseHelper.instance.getLogsForBatch(
              batchNumber,
            );
            if (!mounted) return;
            setState(() {
              _historyLogs =
                  mergeHistoryByIdentity([
                      ...storedLogs,
                      ..._historyLogs,
                    ], historyLogIdentity).values.toList()
                    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
            });
          }, onError: (_) {});
    } catch (_) {}
  }

  void _subscribeToBackgroundUpdates() {
    if (kIsWeb || !_supportsBackgroundService) return;

    try {
      _telemetrySub = FlutterBackgroundService().on('telemetryUpdate').listen((
        event,
      ) {
        if (event != null && mounted) {
          final isLocalUpdate = event['source'] == 'local';
          final applyDeviceState =
              isLocalUpdate ||
              (event['source'] == 'firebase' &&
                  shouldApplyFirebaseDeviceState(
                    localTelemetryFresh: _hasFreshLocalTelemetry,
                  ));
          setState(() {
            if (event['source'] == 'local') {
              _lastLocalTelemetryAt = DateTime.now();
            } else if (event['source'] == 'offline') {
              _lastLocalTelemetryAt = null;
            } else if (event['source'] == 'firebase') {
              if (event['firebaseHeartbeatFresh'] == true) {
                _lastFirebaseTelemetryAt = DateTime.now();
              } else {
                _lastFirebaseTelemetryAt = null;
              }
            }
            _updateConnectionStatus();
            if (applyDeviceState) {
              if (event['bed1'] != null) {
                _bed1 = GrowBedReading.fromMap(
                  Map<String, dynamic>.from(event['bed1'] as Map),
                );
              }
              if (event['reservoir'] is Map) {
                _reservoir = ReservoirReading.fromSources(
                  shared: event['reservoir'],
                );
              }
              if (event['bed2'] != null) {
                _bed2 = GrowBedReading.fromMap(
                  Map<String, dynamic>.from(event['bed2'] as Map),
                );
              }
              if (event['growLight'] != null) {
                _applyGrowLightTelemetry(
                  HydrodeckTelemetry._readBoolLike(
                    {'growLight': event['growLight']},
                    const ['growLight'],
                  ),
                );
              }
              if (event['actuators'] is Map) {
                final actuatorMap = Map<String, dynamic>.from(
                  event['actuators'] as Map,
                );
                _updateActuatorFromFirebase(
                  'bed1_water',
                  'waterPump1',
                  actuatorMap,
                  isLocal: isLocalUpdate,
                );
                _updateActuatorFromFirebase('bed1_ph_up', 'phUp1', actuatorMap);
                _updateActuatorFromFirebase(
                  'bed1_ph_down',
                  'phDown1',
                  actuatorMap,
                );
                _updateActuatorFromFirebase(
                  'bed1_nutrient',
                  'nutrient1',
                  actuatorMap,
                );
                _updateActuatorFromFirebase(
                  'bed2_water',
                  'waterPump2',
                  actuatorMap,
                  isLocal: isLocalUpdate,
                );
                _updateActuatorFromFirebase('bed2_ph_up', 'phUp2', actuatorMap);
                _updateActuatorFromFirebase(
                  'bed2_ph_down',
                  'phDown2',
                  actuatorMap,
                );
                _updateActuatorFromFirebase(
                  'bed2_nutrient',
                  'nutrient2',
                  actuatorMap,
                );
              }
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

      _snapshotSub = FlutterBackgroundService().on('newSnapshotLogged').listen((
        event,
      ) {
        if (event != null && mounted) {
          final newLog = HistoricalData(
            timestamp: DateTime.parse(event['timestamp']),
            pH: (event['pH'] as num).toDouble(),
            temperature: event['temperature'],
            waterLevel: event['waterLevel'],
            tds: (event['tds'] as num?)?.toDouble() ?? 0.0,
            bed1: _decodeBedData(event['bed1']),
            bed2: _decodeBedData(event['bed2']),
            reservoir: ReservoirReading.fromSources(
              shared: event['reservoir'],
              bed1: event['bed1'],
              bed2: event['bed2'],
            ),
            intervalKey: event['intervalKey']?.toString(),
            recordType:
                event['recordType']?.toString() ?? scheduledSnapshotRecordType,
            recordId: event['recordId']?.toString(),
            source: event['source']?.toString() ?? 'esp32',
          );
          setState(() {
            _historyLogs =
                mergeHistoryByIdentity([
                    newLog,
                    ..._historyLogs,
                  ], historyLogIdentity).values.toList()
                  ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
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
      "January",
      "February",
      "March",
      "April",
      "May",
      "June",
      "July",
      "August",
      "September",
      "October",
      "November",
      "December",
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

  void _showCommandMessage(String actuatorName, String message) {
    if (!mounted) return;
    final label = commandActuatorLabel(actuatorName);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label: $message')));
  }

  void _trackPendingCommand(
    String key,
    String actuatorName,
    String commandId,
    DatabaseReference commandRef,
    bool requestedOn,
  ) {
    if (actuatorName == 'growLight') _confirmedGrowLightState = null;
    _pendingCommandIds[actuatorName] = commandId;
    _pendingActuatorStates[key] = requestedOn;
    _actuatorBusy[key] = true;
    _actuatorsSeenRunning.remove(key);
    _actuatorTelemetryTimeouts.remove(key)?.cancel();
    _commandTimeouts[commandId]?.cancel();
    _commandTimeouts[commandId] = Timer(commandAckTimeout, () {
      if (_pendingCommandIds[actuatorName] != commandId) return;
      if (!shouldReleasePendingCommand(timedOut: true)) return;
      final wasAcceptedOrSeen =
          _commandsAcceptedOrRunning.remove(commandId) ||
          _actuatorsSeenRunning.remove(key);
      _pendingCommandIds.remove(actuatorName);
      _commandTimeouts.remove(commandId);
      unawaited(_removeFirebaseCommandRecord(actuatorName, commandId));
      _pendingActuatorStates.remove(key);
      _actuatorBusy[key] = false;
      unawaited(commandRef.remove().catchError((_) {}));
      _showCommandMessage(
        actuatorName,
        friendlyCommandFailureMessage(
          status: wasAcceptedOrSeen ? 'unconfirmed' : 'timed_out',
        ),
      );
      if (mounted) setState(() {});
    });
  }

  void _clearPendingCommand(String actuatorName, String commandId) {
    if (_pendingCommandIds[actuatorName] != commandId) return;
    _pendingCommandIds.remove(actuatorName);
    _commandsAcceptedOrRunning.remove(commandId);
    _commandTimeouts.remove(commandId)?.cancel();
    final key = _getActuatorBusyKey(actuatorName);
    if (key != null) {
      _actuatorTelemetryTimeouts.remove(key)?.cancel();
      _actuatorsSeenRunning.remove(key);
      _pendingActuatorStates.remove(key);
      _actuatorBusy[key] = false;
    }
  }

  Duration _actuatorPulseGrace(String actuatorName) {
    return Duration(seconds: actuatorName.endsWith('1') ? 4 : 6);
  }

  Future<void> _removeFirebaseCommandRecord(
    String actuatorName,
    String commandId,
  ) async {
    try {
      await FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
      ).ref('hydrodeck/commands/$actuatorName/$commandId').remove();
    } catch (_) {}
  }

  void _acceptLocalCommand(
    String key,
    String actuatorName,
    String commandId, {
    bool? growLightState,
  }) {
    _commandsAcceptedOrRunning.add(commandId);
    if (actuatorName.startsWith('waterPump')) {
      return;
    }
    _commandTimeouts.remove(commandId)?.cancel();
    if (actuatorName == 'growLight') {
      if (growLightState != null) {
        _controlStates[key] = growLightState;
        _confirmedGrowLightState = growLightState;
      }
      _clearPendingCommand(actuatorName, commandId);
      if (mounted) setState(() {});
      return;
    }
    final completionGrace = _actuatorPulseGrace(actuatorName);
    _commandTimeouts[commandId] = Timer(completionGrace, () {
      if (_pendingCommandIds[actuatorName] != commandId) return;
      _clearPendingCommand(actuatorName, commandId);
      if (mounted) {
        _showCommandMessage(
          actuatorName,
          friendlyCommandFailureMessage(status: 'unconfirmed'),
        );
        setState(() {});
      }
    });
    if (mounted) setState(() {});
  }

  String _firebaseWriteFailureMessage(Object error) {
    if (error is FirebaseException) {
      final code = error.code.toLowerCase().replaceFirst('database/', '');
      if (code == 'permission-denied') {
        return 'Firebase denied this write. Check the deployed Realtime Database rules.';
      }
      if (code == 'unavailable' || code == 'network-error') {
        return 'Firebase is unavailable right now.';
      }
      if (code == 'transaction-aborted') {
        return 'Firebase could not update the shared data. Retry the change.';
      }
      return 'Firebase write failed ($code).';
    }
    if (error is TimeoutException) {
      return 'Firebase write timed out.';
    }
    return 'Firebase write failed.';
  }

  Future<void> _writeFirebaseCommand({
    required DatabaseReference commandQueue,
    required String commandId,
    required String value,
  }) async {
    final transaction = await commandQueue
        .runTransaction((currentValue) {
          final commands = <String, Object?>{};
          if (currentValue is Map) {
            for (final entry in currentValue.entries) {
              if (entry.key is String) {
                commands[entry.key as String] = entry.value;
              }
            }
          }
          commands.putIfAbsent(commandId, () => value);
          return rtdb.Transaction.success(commands);
        }, applyLocally: false)
        .timeout(const Duration(seconds: 9));
    if (!transaction.committed) {
      throw FirebaseException(
        plugin: 'firebase_database',
        code: 'transaction-aborted',
      );
    }
  }

  List<String> _localControlTargets() {
    return <String>{_esp32Ip.trim(), '192.168.4.1', 'hydrodeck.local'}
        .map(
          (target) => target
              .replaceFirst(RegExp(r'^https?://'), '')
              .replaceFirst(RegExp(r'/.*$'), ''),
        )
        .where((target) => target.isNotEmpty)
        .toList();
  }

  Future<String?> _sendLocalControlCommand({
    required String actuatorName,
    required String commandId,
    required bool requestedOn,
  }) async {
    var lastFailure = 'ESP32_OFFLINE:No ESP32 local HTTP target responded.';
    try {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(true);
      } catch (_) {}
      for (final target in _localControlTargets()) {
        try {
          final response = await http
              .get(
                Uri.http(target, '/control', {
                  'actuator': actuatorName,
                  'state': requestedOn ? '1' : '0',
                  'requestId': commandId,
                }),
                headers: {'Connection': 'close'},
              )
              .timeout(const Duration(seconds: 2));
          if (response.statusCode == 200) {
            await DatabaseHelper.instance.saveActiveIp(target);
            if (mounted) {
              setState(() {
                _esp32Ip = target;
                _lastLocalTelemetryAt = DateTime.now();
              });
            }
            if (_supportsBackgroundService) {
              FlutterBackgroundService().invoke('updateIp', {'ip': target});
            }
            return null;
          }
          if (response.statusCode == 409) {
            return 'ESP32_REJECTED:${response.body}';
          }
          lastFailure = response.statusCode >= 500
              ? 'ESP32_OFFLINE:ESP32 returned HTTP ${response.statusCode}.'
              : 'ESP32_REJECTED:ESP32 returned HTTP ${response.statusCode}.';
        } on TimeoutException {
          lastFailure = 'ESP32_TIMEOUT:The ESP32 request timed out.';
        } catch (_) {
          lastFailure = 'ESP32_OFFLINE:The ESP32 could not be reached.';
        }
      }
    } finally {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      } catch (_) {}
    }
    return lastFailure;
  }

  Future<void> _toggleActuator(String key, String actuatorName) async {
    final isWaterPump = actuatorName.startsWith('waterPump');
    final isGrowLight = actuatorName == 'growLight';
    final currentState = isWaterPump
        ? (_controlStates[key] ?? false)
        : (_pendingActuatorStates[key] ?? _controlStates[key] ?? false);
    final requestedOn = isWaterPump || isGrowLight ? !currentState : true;
    if (isWaterPump &&
        _pendingCommandIds.containsKey(actuatorName) &&
        (_pendingActuatorStates[key] == false || requestedOn)) {
      return;
    }
    if (isWaterPump && requestedOn && !_reservoir.online) {
      _showCommandMessage(actuatorName, 'Rainwater unit offline.');
      return;
    }
    if (isWaterPump && requestedOn && _otherWaterPumpIsRunning(actuatorName)) {
      _showCommandMessage(
        actuatorName,
        'The other water pump is still running.',
      );
      return;
    }
    if (!isWaterPump &&
        (_pendingCommandIds.containsKey(actuatorName) ||
            _actuatorBusy[key] == true)) {
      _showCommandMessage(
        actuatorName,
        'Already running. Wait for this pulse to finish.',
      );
      return;
    }
    final isChemicalPump =
        actuatorName.startsWith('phUp') ||
        actuatorName.startsWith('phDown') ||
        actuatorName.startsWith('nutrient');
    if (isChemicalPump && _chemicalPumpBusy) {
      _showCommandMessage(
        actuatorName,
        'Another dosing pump is still running.',
      );
      return;
    }
    if ((key == 'bed1_ph_down' && _bed1.ph < _minPhThreshold) ||
        (key == 'bed1_ph_up' && _bed1.ph > _maxPhThreshold) ||
        (key == 'bed2_ph_down' && _bed2.ph < _minPhThreshold) ||
        (key == 'bed2_ph_up' && _bed2.ph > _maxPhThreshold)) {
      return;
    }

    final database = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL:
          'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
    );
    final commandQueue = database.ref('hydrodeck/commands/$actuatorName');
    final generatedCommandId = commandQueue.push().key;
    final commandId =
        generatedCommandId ??
        'cmd_${DateTime.now().microsecondsSinceEpoch}_${actuatorName.hashCode.abs()}';
    final commandRef = commandQueue.child(commandId);
    final commandValue = requestedOn ? '1' : '0';

    _trackPendingCommand(key, actuatorName, commandId, commandRef, requestedOn);
    if (mounted) setState(() {});

    final localTelemetryFresh =
        _lastLocalTelemetryAt != null &&
        DateTime.now().difference(_lastLocalTelemetryAt!).inSeconds <= 10;
    final localFirst =
        localTelemetryFresh ||
        _connectionStatus.startsWith('Connected locally');
    var localTried = false;
    var localFailure = 'ESP32 local HTTP was not attempted.';
    var localQueued = false;
    var firebaseQueued = false;
    Object? firebaseFailure;

    if (localFirst) {
      localTried = true;
      localFailure =
          (await _sendLocalControlCommand(
            actuatorName: actuatorName,
            commandId: commandId,
            requestedOn: requestedOn,
          )) ??
          '';
      if (localFailure.startsWith('ESP32_REJECTED:')) {
        _clearPendingCommand(actuatorName, commandId);
        unawaited(commandRef.remove().catchError((_) {}));
        _showCommandMessage(
          actuatorName,
          _friendlyCommandRejection(
            localFailure.substring('ESP32_REJECTED:'.length),
          ),
        );
        return;
      }
      localQueued = localFailure.isEmpty;
      if (localQueued) {
        _acceptLocalCommand(
          key,
          actuatorName,
          commandId,
          growLightState: isGrowLight ? requestedOn : null,
        );
        return;
      }
    }

    try {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      } catch (_) {}
      await _writeFirebaseCommand(
        commandQueue: commandQueue,
        commandId: commandId,
        value: commandValue,
      );
      firebaseQueued = true;
    } catch (error) {
      firebaseFailure = error;
    }

    if (!firebaseQueued && !localTried) {
      localTried = true;
      localFailure =
          (await _sendLocalControlCommand(
            actuatorName: actuatorName,
            commandId: commandId,
            requestedOn: requestedOn,
          )) ??
          '';
      if (localFailure.startsWith('ESP32_REJECTED:')) {
        _clearPendingCommand(actuatorName, commandId);
        unawaited(commandRef.remove().catchError((_) {}));
        _showCommandMessage(
          actuatorName,
          _friendlyCommandRejection(
            localFailure.substring('ESP32_REJECTED:'.length),
          ),
        );
        return;
      }
      localQueued = localFailure.isEmpty;
      if (localQueued) {
        unawaited(commandRef.remove().catchError((_) {}));
        _acceptLocalCommand(
          key,
          actuatorName,
          commandId,
          growLightState: isGrowLight ? requestedOn : null,
        );
        return;
      }
    }

    if (shouldClearPendingAfterDispatch(
      localAccepted: localQueued,
      firebaseQueued: firebaseQueued,
    )) {
      _clearPendingCommand(actuatorName, commandId);
      unawaited(commandRef.remove().catchError((_) {}));
      final firebaseMessage = firebaseFailure == null
          ? 'Firebase was not reachable.'
          : _firebaseWriteFailureMessage(firebaseFailure);
      final localMessage = localFailure.startsWith('ESP32_TIMEOUT:')
          ? friendlyCommandFailureMessage(status: 'timed_out')
          : friendlyCommandFailureMessage(status: 'offline');
      _showCommandMessage(actuatorName, '$firebaseMessage $localMessage');
      if (mounted) setState(() {});
      return;
    }
  }

  Future<void> _connectToEsp32Hotspot() async {
    if (!_hotspotAttemptGate.tryBegin()) return;
    setState(() {
      _hotspotStatus = 'Connecting to $_esp32Hotspot...';
    });
    var failureStage = HotspotFailureStage.connection;
    try {
      final connected = await WiFiForIoTPlugin.connect(
        _esp32Hotspot,
        password: _esp32HotspotPassword,
        security: NetworkSecurity.WPA,
        joinOnce: true,
      ).timeout(const Duration(seconds: 20));
      if (!connected) throw StateError('Hotspot connection failed');
      await WiFiForIoTPlugin.forceWifiUsage(
        true,
      ).timeout(const Duration(seconds: 5));
      final response = await http
          .get(
            Uri.parse('http://192.168.4.1/status'),
            headers: {'Connection': 'close'},
          )
          .timeout(const Duration(seconds: 5));
      failureStage = HotspotFailureStage.response;
      if (response.statusCode != 200) {
        throw const FormatException('Unexpected ESP32 status response');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map ||
          !(decoded.containsKey('wifiConnected') ||
              decoded.containsKey('reservoir') ||
              decoded.containsKey('temp1') ||
              decoded.containsKey('bed1'))) {
        throw const FormatException('Malformed ESP32 status response');
      }
      final telemetry = HydrodeckTelemetry.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      await DatabaseHelper.instance.saveActiveIp('192.168.4.1');
      if (!mounted) return;
      setState(() {
        _esp32Ip = '192.168.4.1';
        _lastLocalTelemetryAt = DateTime.now();
        _bed1 = telemetry.bed1;
        _bed2 = telemetry.bed2;
        _reservoir = telemetry.reservoir;
        _applyGrowLightTelemetry(telemetry.growLightOn);
        _updateActuatorStates(telemetry.actuatorStates, isLocal: true);
        _hotspotStatus = 'Connected to ESP32 hotspot for local control.';
        _updateConnectionStatus();
      });
      if (_supportsBackgroundService) {
        FlutterBackgroundService().invoke('updateIp', {'ip': '192.168.4.1'});
      }
    } catch (_) {
      if (mounted) {
        setState(() => _hotspotStatus = hotspotFailureMessage(failureStage));
      }
    } finally {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      } catch (_) {}
      _hotspotAttemptGate.finish();
      if (mounted) setState(() {});
    }
  }

  void _showOfflineHotspotDialog() {
    if (!mounted ||
        _offlinePromptShown ||
        !shouldShowOfflineHotspotPrompt(
          firebaseConnected: _firebaseConnected,
          localDeviceReachable: _hasFreshLocalTelemetry,
        )) {
      return;
    }
    _offlinePromptShown = true;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('You are offline'),
        content: const Text(
          'You are offline. Connect to the ESP32 hotspot instead?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              unawaited(_connectToEsp32Hotspot());
            },
            icon: const Icon(Icons.wifi),
            label: const Text('Connect to hotspot'),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineBanner() {
    final message = dashboardOfflineBannerMessage(
      firebaseConnected: _firebaseConnected,
      localDeviceReachable: _hasFreshLocalTelemetry,
    );
    if (message == null || _offlineBannerDismissed) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFCC80)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.cloud_off_outlined, color: Colors.deepOrange),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _hasFreshLocalTelemetry
                      ? 'Cloud unavailable'
                      : 'You are offline',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(fontSize: 12, height: 1.3),
                ),
                if (!_hasFreshLocalTelemetry)
                  TextButton.icon(
                    onPressed: _isHotspotConnecting
                        ? null
                        : () => unawaited(_connectToEsp32Hotspot()),
                    icon: const Icon(Icons.wifi, size: 18),
                    label: const Text('Connect to ESP32 hotspot'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.only(top: 6),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Dismiss offline message',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _offlineBannerDismissed = true),
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }

  void _showWifiSetupDialog() {
    if (_wifiPromptShown ||
        _wifiProvisioningCompleted ||
        !mounted ||
        _currentIndex != 0) {
      return;
    }
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
                  const Text(
                    'Find the ESP32 hotspot, then enter the Wi-Fi network the device should join.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: scanning
                        ? null
                        : () async {
                            setDialogState(() {
                              scanning = true;
                              scanMessage = null;
                            });
                            try {
                              final canScan = await WiFiScan.instance
                                  .canStartScan(askPermissions: true);
                              if (canScan != CanStartScan.yes) {
                                throw Exception(
                                  'Wi-Fi scan permission or service is unavailable.',
                                );
                              }
                              final canReadResults = await WiFiScan.instance
                                  .canGetScannedResults(askPermissions: true);
                              if (canReadResults != CanGetScannedResults.yes) {
                                throw Exception(
                                  'Wi-Fi scan results are unavailable.',
                                );
                              }
                              final resultsFuture = WiFiScan
                                  .instance
                                  .onScannedResultsAvailable
                                  .first
                                  .timeout(const Duration(seconds: 12));
                              final started = await WiFiScan.instance
                                  .startScan();
                              if (!started) {
                                throw Exception(
                                  'The Wi-Fi scan did not start.',
                                );
                              }
                              final networks = await resultsFuture;
                              final matches = networks
                                  .map((network) => network.ssid)
                                  .where((ssid) => ssid.contains(_esp32Hotspot))
                                  .toSet()
                                  .toList();
                              if (mounted) {
                                setState(() => _discoveredHotspots = matches);
                              }
                              if (matches.contains(_esp32Hotspot)) {
                                selectedHotspot = _esp32Hotspot;
                              }
                              setDialogState(() {
                                scanning = false;
                                scanMessage = matches.isEmpty
                                    ? hotspotFailureMessage(
                                        HotspotFailureStage.discovery,
                                      )
                                    : null;
                              });
                            } catch (_) {
                              setDialogState(() {
                                scanning = false;
                                scanMessage = hotspotFailureMessage(
                                  HotspotFailureStage.discovery,
                                );
                              });
                            }
                          },
                    icon: const Icon(Icons.wifi_find),
                    label: Text(
                      scanning ? 'Searching...' : 'Search for ESP32 hotspot',
                    ),
                  ),
                  if (_discoveredHotspots.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: selectedHotspot,
                      decoration: const InputDecoration(
                        labelText: 'ESP32 hotspot',
                      ),
                      items: _discoveredHotspots
                          .map(
                            (ssid) => DropdownMenuItem(
                              value: ssid,
                              child: Text(ssid),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setDialogState(() => selectedHotspot = value),
                    ),
                  if (scanMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      scanMessage!,
                      style: const TextStyle(
                        color: Colors.orange,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _wifiSsidController,
                    decoration: const InputDecoration(
                      labelText: 'New Wi-Fi SSID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _PasswordVisibilityField(
                    controller: _wifiPasswordController,
                    label: 'New Wi-Fi password',
                    icon: Icons.lock_outline,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Later'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _connectAndProvisionWifi(
                    hotspotSsid: selectedHotspot ?? _esp32Hotspot,
                  );
                },
                child: const Text('Connect'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _connectAndProvisionWifi({
    String hotspotSsid = _esp32Hotspot,
  }) async {
    final ssid = _wifiSsidController.text.trim();
    final password = _wifiPasswordController.text;
    if (ssid.isEmpty || password.isEmpty) {
      setState(() => _hotspotStatus = 'Enter both Wi-Fi fields first');
      return;
    }

    if (!_hotspotAttemptGate.tryBegin()) return;
    setState(
      () => _hotspotStatus =
          'Connecting to the ESP32 and sending Wi-Fi details...',
    );
    var failureStage = HotspotFailureStage.connection;
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    var credentialsAccepted = false;
    try {
      final connected = await WiFiForIoTPlugin.connect(
        hotspotSsid,
        password: _esp32HotspotPassword,
        security: NetworkSecurity.WPA,
        joinOnce: true,
      ).timeout(const Duration(seconds: 20));
      if (!connected) throw StateError('Hotspot connection failed');
      await WiFiForIoTPlugin.forceWifiUsage(
        true,
      ).timeout(const Duration(seconds: 5));
      failureStage = HotspotFailureStage.response;
      Map<String, dynamic> responseData;
      int responseStatus;
      try {
        final response = await http
            .post(
              Uri.parse('http://192.168.4.1/provision'),
              headers: const {'Connection': 'close'},
              body: {
                'ssid': ssid,
                'password': password,
                'requestId': requestId,
              },
            )
            .timeout(const Duration(seconds: 10));
        responseData = _readProvisioningResponse(response.body);
        responseStatus = response.statusCode;
      } catch (_) {
        // Recover if the ESP32 accepted the request but its POST response was lost.
        final recoveredResponse = await http
            .get(
              Uri.https('192.168.4.1', '/provision/status', {
                'requestId': requestId,
              }),
              headers: const {'Connection': 'close'},
            )
            .timeout(const Duration(seconds: 5));
        responseData = _readProvisioningResponse(recoveredResponse.body);
        responseStatus = recoveredResponse.statusCode == 200 ? 202 : 500;
      }
      var statusCode = responseData['status'] as String?;
      if (statusCode == 'busy' && responseData['requestId'] == requestId) {
        if (mounted) {
          setState(() => _hotspotStatus = wifiProvisioningMessage(statusCode));
        }
        return;
      }
      if (responseData['requestId'] != requestId ||
          !isWifiProvisioningAccepted(statusCode)) {
        throw StateError('ESP32 did not confirm credential receipt');
      }
      if (responseStatus != 200 &&
          responseStatus != 202 &&
          !(responseStatus == 400 &&
              (statusCode == 'missing_credentials' ||
                  statusCode == 'invalid_credentials'))) {
        throw StateError('ESP32 did not accept the provisioning request');
      }

      // Start the connection-result timeout only after receipt is acknowledged.
      credentialsAccepted = true;
      if (mounted) {
        setState(() => _hotspotStatus = wifiProvisioningMessage(statusCode));
      }
      final timer = Stopwatch()..start();
      var consecutivePollFailures = 0;
      while (isWifiProvisioningPending(statusCode) &&
          timer.elapsed < const Duration(seconds: 40)) {
        if (mounted) {
          setState(() => _hotspotStatus = wifiProvisioningMessage(statusCode));
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        try {
          final statusResponse = await http
              .get(
                Uri.https('192.168.4.1', '/provision/status', {
                  'requestId': requestId,
                }),
                headers: const {'Connection': 'close'},
              )
              .timeout(const Duration(seconds: 4));
          responseData = _readProvisioningResponse(statusResponse.body);
          if (statusResponse.statusCode != 200 ||
              responseData['requestId'] != requestId) {
            consecutivePollFailures++;
            continue;
          }
          statusCode = responseData['status'] as String?;
          consecutivePollFailures = 0;
        } catch (_) {
          consecutivePollFailures++;
          if (consecutivePollFailures >= 4) break;
        }
      }

      if (isWifiProvisioningFinal(statusCode)) {
        _wifiProvisioningCompleted = true;
        _wifiPromptShown = true;
        var disconnected = false;
        try {
          await WiFiForIoTPlugin.forceWifiUsage(false);
          disconnected = await WiFiForIoTPlugin.disconnect().timeout(
            const Duration(seconds: 5),
          );
        } catch (_) {
          disconnected = false;
        }
        if (mounted) {
          setState(
            () => _hotspotStatus = completedProvisioningMessage(
              result: statusCode!,
              disconnectedFromHotspot: disconnected,
            ),
          );
        }
      } else {
        if (mounted) {
          setState(
            () => _hotspotStatus =
                'The ESP32 received your Wi-Fi details, but the result could not be confirmed. '
                'You can retry or check the ESP32 status.',
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _hotspotStatus = credentialsAccepted
              ? 'The ESP32 received your Wi-Fi details, but the result could not be confirmed. Retry or check status.'
              : hotspotFailureMessage(failureStage),
        );
      }
    } finally {
      _wifiPromptShown = true;
      try {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      } catch (_) {}
      _hotspotAttemptGate.finish();
      if (mounted) setState(() {});
    }
  }

  Map<String, dynamic> _readProvisioningResponse(String responseBody) {
    final response = Map<String, dynamic>.from(jsonDecode(responseBody) as Map);
    final status = response['status'];
    const knownStatuses = {
      'received',
      'scanning',
      'testing',
      'rain_pending',
      'rain_unconfirmed',
      'rain_rejected',
      'connected',
      'network_unavailable',
      'authentication_failed',
      'connection_failed',
      'timeout',
      'missing_credentials',
      'invalid_credentials',
      'busy',
      'unknown_request',
      'invalid_request',
    };
    if (status is! String || !knownStatuses.contains(status)) {
      throw const FormatException('Malformed ESP32 provisioning response');
    }
    return response;
  }

  Future<void> _publishPhThresholds() async {
    if (!isValidPhThresholds(_minPhThreshold, _maxPhThreshold)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Use a minimum pH from 4.0 to 7.0 and a maximum from 6.0 to 9.0, with minimum below maximum.',
            ),
          ),
        );
      }
      return;
    }
    try {
      try {
        await WiFiForIoTPlugin.forceWifiUsage(false);
      } catch (_) {}
      final settingsRef = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL:
            'https://hydrodeck-e6fea-default-rtdb.asia-southeast1.firebasedatabase.app/',
      ).ref('hydrodeck/settings');
      await settingsRef
          .update({'minPh': _minPhThreshold, 'maxPh': _maxPhThreshold})
          .timeout(const Duration(seconds: 8));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_firebaseWriteFailureMessage(error))),
        );
      }
    }
    await _postPhThresholdsToLocalEsp32(_minPhThreshold, _maxPhThreshold);
  }

  void _updatePhThresholds(double minimum, double maximum) {
    if (!isValidPhThresholds(minimum, maximum)) return;
    setState(() {
      _minPhThreshold = minimum;
      _maxPhThreshold = maximum;
    });
    unawaited(DatabaseHelper.instance.saveSettingsConfig(minimum, maximum));
    _schedulePhThresholdPublish();
    if (_supportsBackgroundService) {
      FlutterBackgroundService().invoke('updateLimits', {
        'minPh': minimum,
        'maxPh': maximum,
      });
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
        title: const Text('Home & connection help'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Connect the ESP32',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 10),
              Text(
                '1. Power on the ESP32. In Settings, open ESP32 Hotspot Setup and tap Connect to ESP32 Hotspot.',
              ),
              SizedBox(height: 10),
              Text(
                '2. To put the ESP32 on your home Wi-Fi, enter that network’s name and password, then tap Send Wi-Fi to ESP32.',
              ),
              SizedBox(height: 10),
              Text(
                '3. For direct local access, connect your phone to the same Wi-Fi as the ESP32, or use its hotspot.',
              ),
              SizedBox(height: 14),
              Text(
                'Connection status',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 6),
              Text(
                'Connected locally means this phone received a direct /status reply from the ESP32. Online means HydroDeck sees a recent ESP32 heartbeat through Firebase. Wi-Fi alone does not mean internet or cloud access is working.',
              ),
              SizedBox(height: 14),
              Text('Readings', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text(
                'pH shows how acidic or alkaline the grow-bed water is; compare it with the target limits in Settings.',
              ),
              SizedBox(height: 6),
              Text(
                'TDS (PPM) estimates dissolved nutrients and minerals in the water.',
              ),
              SizedBox(height: 6),
              Text('Water temperature is shown in °C.'),
              SizedBox(height: 6),
              Text(
                'Grow-bed water level reports whether each bed sensor says Water full or Needs water.',
              ),
              SizedBox(height: 6),
              Text(
                'Reservoir shows the rainwater tank level and whether the separate RAIN unit is online.',
              ),
              SizedBox(height: 14),
              Text(
                'If a reading or command times out, the phone may have lost local Wi-Fi/device communication. A cloud-based request can also time out when internet or Firebase is unavailable.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showControlsHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Controls help'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Using the controls',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'Water pumps turn on or off for their grow bed. Only one water pump may run at a time, and a pump cannot start when the RAIN reservoir unit is offline.',
              ),
              SizedBox(height: 8),
              Text(
                'Nutrient and pH buttons run dosing pumps. Only one chemical dose runs at a time. The pH + or − button is enabled only when the reading and target limits call for that adjustment.',
              ),
              SizedBox(height: 8),
              Text('Use the Grow Light button to switch the light on or off.'),
              SizedBox(height: 14),
              Text(
                'Why a control may be locked',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text(
                'A control can be temporarily unavailable while a command is waiting for confirmation, a dosing pulse is running, the other water pump is on, or the reservoir unit is offline. Wait for the status to update before trying again.',
              ),
              SizedBox(height: 14),
              Text(
                'If a reading or command times out, the phone may have lost local Wi-Fi/device communication. A cloud-based request can also time out when internet or Firebase is unavailable.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
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
      NotificationsScreen(
        onUnreadCountChanged: (unreadCount) {
          if (mounted && unreadCount != _unreadPhAlertCount) {
            setState(() => _unreadPhAlertCount = unreadCount);
          }
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: _currentIndex == 4 ? const Text('Notifications') : null,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        actions: _currentIndex == 3
            ? [
                IconButton(
                  icon: const Icon(Icons.person_outline),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const ProfileScreen(),
                      ),
                    );
                  },
                ),
              ]
            : const [],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_firebaseConnected == false && !_offlineBannerDismissed)
              _buildOfflineBanner(),
            Expanded(child: screens[_currentIndex]),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF2DC867),
        unselectedItemColor: Colors.grey,
        selectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 11,
        ),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.home), label: 'HOME'),
          BottomNavigationBarItem(
            icon: const Icon(Icons.grid_view),
            label: 'CONTROLS',
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.bar_chart_outlined),
            label: 'DATA',
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.settings_outlined),
            label: 'SETTINGS',
          ),
          BottomNavigationBarItem(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_outlined),
                if (_unreadPhAlertCount > 0)
                  Positioned(
                    top: -2,
                    right: -3,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            label: 'ALERTS',
          ),
        ],
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
          if (index == 4) unawaited(_refreshUnreadPhAlertCount());
        },
      ),
    );
  }

  // Home screen
  Widget _buildHomeScreen(String waterLabel) {
    final statusColor = _connectionStatus == 'ESP32 offline'
        ? Colors.orange
        : Colors.green;
    final isBed1Warning =
        _bed1.ph < _minPhThreshold || _bed1.ph > _maxPhThreshold;
    final isBed2Warning =
        _bed2.ph < _minPhThreshold || _bed2.ph > _maxPhThreshold;
    final hasPhWarning = isBed1Warning || isBed2Warning;
    final currentDayCount = _getElapsedPlantingDay(
      _serverNow ?? DateTime.now(),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Home',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
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
                    onPressed: _isRefreshingConnectivity
                        ? null
                        : () => _refreshConnectivity(),
                    icon: _isRefreshingConnectivity
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
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
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _connectionStatus,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          const WeatherHomeCard(),
          const SizedBox(height: 20),

          hasPhWarning
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.red[400],
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.withAlpha(50),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
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
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.1,
                            ),
                          ),
                          Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.white,
                            size: 26,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'pH ALERT',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isBed1Warning && isBed2Warning
                            ? 'Grow beds 1 and 2 are outside the target range at ${_bed1.ph.toStringAsFixed(2)} and ${_bed2.ph.toStringAsFixed(2)} pH. Target range is ${_minPhThreshold.toStringAsFixed(1)} - ${_maxPhThreshold.toStringAsFixed(1)} pH.'
                            : isBed1Warning
                            ? 'Grow bed 1 is outside the target range at ${_bed1.ph.toStringAsFixed(2)} pH. Target range is ${_minPhThreshold.toStringAsFixed(1)} - ${_maxPhThreshold.toStringAsFixed(1)} pH.'
                            : 'Grow bed 2 is outside the target range at ${_bed2.ph.toStringAsFixed(2)} pH. Target range is ${_minPhThreshold.toStringAsFixed(1)} - ${_maxPhThreshold.toStringAsFixed(1)} pH.',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.4,
                        ),
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
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2DC867).withAlpha(50),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Current Status',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          Icon(
                            Icons.wb_sunny_outlined,
                            color: Colors.white.withAlpha(230),
                            size: 24,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Optimal Growth',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(45),
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: Text(
                              'Day $currentDayCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
          const SizedBox(height: 24),
          const Text(
            'Grow Bed 1 Metrics',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildGrowBedMetrics('Grow Bed 1', _bed1),
          const SizedBox(height: 24),
          const Text(
            'Grow Bed 2 Metrics',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildGrowBedMetrics('Grow Bed 2', _bed2),
          const SizedBox(height: 24),
          _buildCleanCard(
            'RESERVOIR',
            reservoirLabel(_reservoir.level),
            _reservoir.online ? 'RAIN online' : 'RAIN offline',
            _reservoir.online
                ? const Color(0xFFE8F7ED)
                : const Color(0xFFFFF3E0),
            _reservoir.online ? Colors.green.shade800 : Colors.orange,
          ),
        ],
      ),
    );
  }

  // TDS, pH, temperature, and water-level metrics
  Widget _buildGrowBedMetrics(String title, GrowBedReading data) {
    final isPhOptimal =
        data.ph >= _minPhThreshold && data.ph <= _maxPhThreshold;
    final isTdsOptimal = data.tds < 900;
    final temperatureStatus = temperatureStatusLabel(
      temperature: data.temperature,
      valid: data.temperatureValid,
      fresh: _hasFreshSensorTelemetry,
    );
    final temperatureHot = temperatureStatus == 'Too hot';
    final temperatureUnavailable = temperatureStatus == 'Unavailable';
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
                icon: Icons.science_outlined,
                iconColor: isPhOptimal ? Colors.green : Colors.orange,
                iconSemanticLabel: 'pH measurement',
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildCleanCard(
                'TDS',
                '${data.tds.toStringAsFixed(0)} PPM',
                isTdsOptimal ? 'Optimal' : 'Warning',
                isTdsOptimal
                    ? const Color(0xFFE8F7ED)
                    : const Color(0xFFFFF3E0),
                isTdsOptimal ? Colors.green : Colors.orange,
                icon: Icons.water_drop_outlined,
                iconColor: const Color(0xFF168AAD),
                iconSemanticLabel: 'Total dissolved solids',
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
                temperatureUnavailable
                    ? '—'
                    : '${data.temperature.toStringAsFixed(1)}°C',
                temperatureStatus,
                temperatureHot
                    ? const Color(0xFFFFEBEE)
                    : temperatureUnavailable
                    ? const Color(0xFFF0F0F0)
                    : const Color(0xFFE8F4FD),
                temperatureHot
                    ? Colors.red.shade700
                    : temperatureUnavailable
                    ? Colors.grey
                    : Colors.blue.shade700,
                icon: temperatureHot
                    ? Icons.thermostat
                    : Icons.device_thermostat,
                iconColor: temperatureHot
                    ? Colors.red.shade700
                    : temperatureUnavailable
                    ? Colors.grey
                    : Colors.blue.shade700,
                iconSemanticLabel: 'Thermometer, $temperatureStatus',
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildCleanCard(
                'BED WATER LEVEL',
                waterLabel,
                data.waterFull ? 'Full' : 'Low',
                data.waterFull
                    ? const Color(0xFFE8F7ED)
                    : const Color(0xFFFFF3E0),
                data.waterFull ? Colors.green : Colors.orange,
                icon: data.waterFull ? Icons.water : Icons.water_drop_outlined,
                iconColor: data.waterFull ? Colors.blue : Colors.blueGrey,
                iconSemanticLabel: waterLabel,
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
      child: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
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
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                'Grow bed $bedIndex',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: Text(
                bed.ph.toStringAsFixed(2),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 54,
              height: 52,
              child: ElevatedButton(
                onPressed:
                    _chemicalPumpBusy ||
                        _actuatorBusy[minusKey] == true ||
                        _actuatorBusy[plusKey] == true ||
                        bed.ph < _minPhThreshold
                    ? null
                    : () => _toggleActuator(minusKey, minusName),
                style: ElevatedButton.styleFrom(
                  backgroundColor: minusNeeded
                      ? Colors.red
                      : Colors.grey.shade200,
                  foregroundColor: minusNeeded ? Colors.white : Colors.black87,
                  padding: EdgeInsets.zero,
                ),
                child: const Text(
                  '-',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 54,
              height: 52,
              child: ElevatedButton(
                onPressed:
                    _chemicalPumpBusy ||
                        _actuatorBusy[plusKey] == true ||
                        _actuatorBusy[minusKey] == true ||
                        bed.ph > _maxPhThreshold
                    ? null
                    : () => _toggleActuator(plusKey, plusName),
                style: ElevatedButton.styleFrom(
                  backgroundColor: plusNeeded
                      ? Colors.green
                      : Colors.grey.shade200,
                  foregroundColor: plusNeeded ? Colors.white : Colors.black87,
                  padding: EdgeInsets.zero,
                ),
                child: const Text(
                  '+',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      );
    }

    Widget pumpRow(int bedIndex, {required bool nutrient}) {
      final key = nutrient ? 'bed${bedIndex}_nutrient' : 'bed${bedIndex}_water';
      final actuator = nutrient
          ? (bedIndex == 1 ? 'nutrient1' : 'nutrient2')
          : (bedIndex == 1 ? 'waterPump1' : 'waterPump2');
      final needsWater = bedIndex == 1 ? !_bed1.waterFull : !_bed2.waterFull;
      final isOn = _controlStates[key] ?? false;
      final rainNodeOnline = _reservoir.online;
      final commandPending = _pendingCommandIds.containsKey(actuator);
      return Column(
        children: [
          Container(
            color: !nutrient && needsWater
                ? Colors.yellow.shade100
                : Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Grow bed $bedIndex',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(
                  width: 112,
                  height: 48,
                  child: ElevatedButton(
                    key: nutrient
                        ? null
                        : ValueKey('water-pump-$bedIndex-toggle'),
                    onPressed: nutrient
                        ? (_actuatorBusy[key] == true || _chemicalPumpBusy
                              ? null
                              : () => _toggleActuator(key, actuator))
                        : (commandPending &&
                                  (!isOn ||
                                      _pendingActuatorStates[key] == false)
                              ? null
                              : (!isOn &&
                                        (!rainNodeOnline ||
                                            _otherWaterPumpIsRunning(actuator))
                                    ? null
                                    : () => _toggleActuator(key, actuator))),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: !nutrient && isOn
                          ? const Color(0xFF2DC867)
                          : !nutrient && needsWater
                          ? Colors.amber.shade300
                          : Colors.grey.shade200,
                      foregroundColor: !nutrient && isOn
                          ? Colors.white
                          : Colors.black87,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      nutrient
                          ? 'ADD'
                          : isOn
                          ? 'ON'
                          : 'OFF',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    Widget separatedRows(List<Widget> rows) => Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) Divider(height: 1, color: Colors.grey.shade200),
            rows[index],
          ],
        ],
      ),
    );

    final growLightOn = _controlStates['grow_light'] ?? false;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'Hardware Controls',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: 'Controls help',
                onPressed: _showControlsHelp,
                icon: const Icon(Icons.help_outline),
              ),
            ],
          ),
          sectionTitle('PH LEVEL'),
          separatedRows([phRow(1, _bed1), phRow(2, _bed2)]),
          sectionTitle('WATER PUMP'),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Reservoir: ${reservoirLabel(_reservoir.level)}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                Text(
                  _reservoir.online ? 'Online' : 'Offline',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _reservoir.online ? Colors.green : Colors.orange,
                  ),
                ),
              ],
            ),
          ),
          separatedRows([
            pumpRow(1, nutrient: false),
            pumpRow(2, nutrient: false),
          ]),
          sectionTitle('NUTRIENT SOLUTION'),
          separatedRows([
            pumpRow(1, nutrient: true),
            pumpRow(2, nutrient: true),
          ]),
          sectionTitle('GROW LIGHT'),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              key: const ValueKey('grow-light-button'),
              onPressed: _actuatorBusy['grow_light'] == true
                  ? null
                  : () => _toggleActuator('grow_light', 'growLight'),
              style: ElevatedButton.styleFrom(
                backgroundColor: growLightOn
                    ? const Color(0xFF2DC867)
                    : Colors.grey.shade200,
                foregroundColor: growLightOn ? Colors.white : Colors.black87,
              ),
              child: Text(
                growLightOn ? 'ON' : 'OFF',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
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
              const Text(
                'System Log Data',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: Icon(
                  Icons.filter_alt_outlined,
                  color: _selectedFilterDate != null
                      ? const Color(0xFF2DC867)
                      : Colors.grey,
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
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2DC867),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _selectedFilterDate = null),
                  child: const Text(
                    'Clear Filter',
                    style: TextStyle(fontSize: 11, color: Colors.red),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 12),
          const Text(
            'Saved ESP32 snapshots (every 20 minutes, Manila time):',
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filteredLogs.isEmpty
                ? const Center(
                    child: Text(
                      'No historical snapshots logged on this date.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: listElements.length,
                    itemBuilder: (context, index) {
                      final item = listElements[index];

                      if (item is String) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 10.0,
                            horizontal: 4.0,
                          ),
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
                      return Dismissible(
                        key: ValueKey(log.identity),
                        direction: DismissDirection.endToStart,
                        secondaryBackground: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: Colors.red.shade700,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.centerRight,
                          child: const Icon(
                            Icons.delete_outline,
                            color: Colors.white,
                          ),
                        ),
                        confirmDismiss: (_) async {
                          final messenger = ScaffoldMessenger.of(context);
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialogContext) => AlertDialog(
                              title: const Text('Delete local log?'),
                              content: const Text(
                                'This removes the log from this device only. Any cloud-synced copy is not deleted.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(dialogContext, true),
                                  child: const Text(
                                    'Delete from device',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true) return false;
                          try {
                            final deleted = await DatabaseHelper.instance
                                .deleteLocalLog(log.identity);
                            if (!deleted && mounted) {
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'This local log no longer exists.',
                                  ),
                                ),
                              );
                            }
                            return deleted;
                          } catch (error) {
                            if (mounted) {
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Could not delete the local log: $error',
                                  ),
                                ),
                              );
                            }
                            return false;
                          }
                        },
                        onDismissed: (_) {
                          setState(() {
                            _historyLogs.removeWhere(
                              (item) => item.identity == log.identity,
                            );
                          });
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            title: Text(
                              _formatDateTimeToReadable(log.timestamp),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.grey,
                            ),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => SnapshotDetailScreen(
                                    data: log,
                                    formattedTime: _formatDateTimeToReadable(
                                      log.timestamp,
                                    ),
                                    minPh: _minPhThreshold,
                                    maxPh: _maxPhThreshold,
                                  ),
                                ),
                              );
                            },
                          ),
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
          const Text(
            'Settings',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),

          const Text(
            'ESP32 Hotspot Setup',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                TextField(
                  controller: _wifiSsidController,
                  decoration: const InputDecoration(
                    labelText: 'Wi-Fi SSID',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                _PasswordVisibilityField(
                  controller: _wifiPasswordController,
                  label: 'Wi-Fi Password',
                  icon: Icons.lock_outline,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isHotspotConnecting
                        ? null
                        : _connectAndProvisionWifi,
                    icon: _isHotspotConnecting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.wifi_find),
                    label: Text(
                      _isHotspotConnecting
                          ? 'Sending...'
                          : 'Send Wi-Fi to ESP32',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2DC867),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isHotspotConnecting
                        ? null
                        : _connectToEsp32Hotspot,
                    icon: const Icon(Icons.wifi),
                    label: Text(
                      _isHotspotConnecting
                          ? 'Connecting...'
                          : 'Connect to ESP32 Hotspot',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _hotspotStatus,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          const Text(
            'Target Limit Parameters',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),

          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Minimum pH Limit',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      _minPhThreshold.toStringAsFixed(1),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.orange,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _minPhThreshold,
                  min: 4.0,
                  max: (_maxPhThreshold - 0.1).clamp(4.1, 7.0).toDouble(),
                  divisions:
                      (((_maxPhThreshold - 0.1).clamp(4.1, 7.0).toDouble() -
                                  4.0) *
                              10)
                          .round(),
                  activeColor: Colors.orange,
                  onChanged: (val) => _updatePhThresholds(val, _maxPhThreshold),
                ),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Maximum pH Limit',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      _maxPhThreshold.toStringAsFixed(1),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _maxPhThreshold,
                  min: (_minPhThreshold + 0.1).clamp(6.0, 8.9).toDouble(),
                  max: 9.0,
                  divisions:
                      ((9.0 -
                                  (_minPhThreshold + 0.1)
                                      .clamp(6.0, 8.9)
                                      .toDouble()) *
                              10)
                          .round(),
                  activeColor: Colors.green,
                  onChanged: (val) => _updatePhThresholds(_minPhThreshold, val),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          PolicySettingsSection(
            onContactSupport: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SupportRequestScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 32),

          ElevatedButton(
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('End Planting Cycle?'),
                  content: const Text(
                    'This will archive your current dynamic run and log the final day count to your planting records.',
                  ),
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
                      child: const Text(
                        'End Cycle',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 56),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
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

  Widget _buildCleanCard(
    String title,
    String value,
    String? badgeText,
    Color bg,
    Color text, {
    IconData? icon,
    Color? iconColor,
    String? iconSemanticLabel,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(5),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
              ),
              if (icon != null)
                Icon(
                  icon,
                  size: 21,
                  color: iconColor ?? Colors.blueGrey,
                  semanticLabel: iconSemanticLabel,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          if (badgeText != null && badgeText.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                badgeText,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: text,
                ),
              ),
            ),
          ],
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
    _logsFuture = DatabaseHelper.instance.getLogsForBatch(
      widget.record.batchNumber,
    );
  }

  String _formatDateTime(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final period = value.hour >= 12 ? 'PM' : 'AM';
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} $hour:${value.minute.toString().padLeft(2, '0')} $period';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Batch #${widget.record.batchNumber} System Logs'),
      ),
      body: FutureBuilder<List<HistoricalData>>(
        future: _logsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFF2DC867)),
            );
          }
          final logs = snapshot.data!;
          if (logs.isEmpty) {
            return const Center(
              child: Text('No system logs recorded for this batch.'),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final log = logs[index];
              return Card(
                child: ListTile(
                  title: Text(_formatDateTime(log.timestamp)),
                  subtitle: Text(
                    'pH ${log.pH.toStringAsFixed(2)}  |  ${log.temperature}  |  ${log.waterLevel}  |  TDS ${log.tds.toStringAsFixed(1)}  |  Reservoir ${reservoirLabel(log.reservoir.level)}',
                  ),
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
        title: const Text(
          'Data Log Detail',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: Colors.black,
          ),
        ),
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
            const Text(
              'Overview - Captured State',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'Logged: $formattedTime',
              style: const TextStyle(
                color: Colors.grey,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),

            const Text(
              'Grow Bed 1 (Historical Metrics)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _buildStaticGrid(bed1, bed1WaterFull, bed1PhOptimal),

            const SizedBox(height: 24),
            const Text(
              'Grow Bed 2 (Historical Metrics)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _buildStaticGrid(bed2, bed2WaterFull, bed2PhOptimal),
            const SizedBox(height: 24),
            const Text(
              'Shared Reservoir',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _buildStaticCard(
              'RESERVOIR',
              reservoirLabel(data.reservoir.level),
              data.reservoir.online ? 'RAIN online' : 'RAIN offline',
              bgOverride: data.reservoir.online
                  ? const Color(0xFFE8F7ED)
                  : const Color(0xFFFFF3E0),
              textOverride: data.reservoir.online
                  ? Colors.green.shade800
                  : Colors.orange,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStaticGrid(
    GrowBedReading bed,
    bool isWaterFull,
    bool isPhOptimal,
  ) {
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
                bgOverride: isPhOptimal
                    ? const Color(0xFFE8F7ED)
                    : const Color(0xFFFFF3E0),
                textOverride: isPhOptimal ? Colors.green : Colors.orange,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildStaticCard(
                'TDS',
                '${bed.tds.toStringAsFixed(0)} PPM',
                isTdsOptimal ? 'Optimal' : 'Warning',
                bgOverride: isTdsOptimal
                    ? const Color(0xFFE8F7ED)
                    : const Color(0xFFFFF3E0),
                textOverride: isTdsOptimal ? Colors.green : Colors.orange,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildStaticCard(
                'WATER TEMP',
                '${bed.temperature.toStringAsFixed(1)}°C',
                'Log Data',
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildStaticCard(
                'GROW BED WATER LEVEL',
                isWaterFull ? 'Water Full' : 'Needs Water',
                isWaterFull ? 'Optimal' : 'Warning',
                bgOverride: isWaterFull
                    ? const Color(0xFFE8F7ED)
                    : const Color(0xFFFFF3E0),
                textOverride: isWaterFull ? Colors.green : Colors.orange,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStaticCard(
    String title,
    String value,
    String? badgeText, {
    Color? bgOverride,
    Color? textOverride,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(5),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (badgeText != null && badgeText.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: bgOverride ?? const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                badgeText,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: textOverride ?? Colors.grey,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

int? _parseHeartbeatMillis(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  if (value is Map) {
    for (final key in const ['timestamp', 'millis', 'value', '.sv']) {
      final parsed = _parseHeartbeatMillis(value[key]);
      if (parsed != null) return parsed;
    }
  }
  return null;
}
