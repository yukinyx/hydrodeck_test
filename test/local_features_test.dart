import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:hydrodeck_test/main.dart';
import 'package:hydrodeck_test/critical_ph_policy.dart';
import 'package:hydrodeck_test/weather_service.dart';

void main() {
  sqfliteFfiInit();

  late Database database;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE historical_logs (recordId TEXT PRIMARY KEY)',
          );
          await db.execute('''
            CREATE TABLE local_history_deletions (
              recordId TEXT PRIMARY KEY,
              deletedAt TEXT NOT NULL
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
              id INTEGER PRIMARY KEY,
              name TEXT NOT NULL,
              latitude REAL NOT NULL,
              longitude REAL NOT NULL
            )
          ''');
          await db.execute(
            'CREATE TABLE remote_logs (recordId TEXT PRIMARY KEY)',
          );
        },
      ),
    );
    DatabaseHelper.setDatabaseForTesting(database);
  });

  tearDown(() async {
    DatabaseHelper.setDatabaseForTesting(null);
    await database.close();
  });

  test('local history deletion leaves remote records untouched', () async {
    await database.insert('historical_logs', {'recordId': 'keep-local'});
    await database.insert('historical_logs', {'recordId': 'delete-local'});
    await database.insert('remote_logs', {'recordId': 'delete-local'});

    expect(
      await DatabaseHelper.instance.deleteLocalLog('delete-local'),
      isTrue,
    );
    expect(
      (await database.query(
        'historical_logs',
      )).map((row) => row['recordId']).toList(),
      ['keep-local'],
    );
    expect(
      await DatabaseHelper.instance.isLocalLogDeleted('delete-local'),
      isTrue,
    );
    expect(
      await DatabaseHelper.instance.insertLogIfMissing(
        HistoricalData(
          timestamp: DateTime.utc(2026, 11, 8),
          pH: 5.2,
          temperature: '24°C',
          waterLevel: 'Water full',
          tds: 400,
          recordId: 'delete-local',
        ),
        cloudSynced: true,
      ),
      isFalse,
    );
    expect(await database.query('remote_logs'), hasLength(1));
  });

  test(
    'pH alert inbox deduplicates, marks read, and clears unread alerts',
    () async {
      final createdAt = DateTime.utc(2026, 11, 8, 8);
      await DatabaseHelper.instance.insertPhAlert(
        alertId: 'episode-1',
        ph: 5.1,
        createdAt: createdAt,
      );
      await DatabaseHelper.instance.insertPhAlert(
        alertId: 'episode-1',
        ph: 5.1,
        createdAt: createdAt,
      );

      expect(await DatabaseHelper.instance.getUnreadPhAlertCount(), 1);
      expect(await DatabaseHelper.instance.getPhAlerts(), hasLength(1));
      await DatabaseHelper.instance.markPhAlertRead('episode-1');
      expect(await DatabaseHelper.instance.getUnreadPhAlertCount(), 0);

      await DatabaseHelper.instance.clearPhAlerts();
      expect(await DatabaseHelper.instance.getPhAlerts(), isEmpty);
      expect(await DatabaseHelper.instance.getUnreadPhAlertCount(), 0);
    },
  );

  test('weather location is stored locally for later refreshes', () async {
    const location = WeatherLocation(
      name: 'Quezon City, Metro Manila, Philippines',
      latitude: 14.676,
      longitude: 121.0437,
    );
    await DatabaseHelper.instance.saveWeatherLocation(location);

    final saved = await DatabaseHelper.instance.getWeatherLocation();
    expect(saved?.name, location.name);
    expect(saved?.latitude, location.latitude);
    expect(saved?.longitude, location.longitude);
  });

  test('a pH episode keeps one deduplication ID until it resets', () {
    final episode = CriticalPhEpisode();
    final startedAt = DateTime.utc(2026, 11, 8, 8);

    expect(
      episode.shouldNotify(ph: 5.1, minimum: 5.5, maximum: 7, now: startedAt),
      isFalse,
    );
    final alertId = episode.notificationId;
    expect(alertId, isNotNull);
    expect(
      episode.shouldNotify(
        ph: 5.1,
        minimum: 5.5,
        maximum: 7,
        now: startedAt.add(const Duration(seconds: 30)),
      ),
      isFalse,
    );
    expect(episode.notificationId, alertId);

    episode.reset();
    expect(episode.notificationId, isNull);
  });
}
