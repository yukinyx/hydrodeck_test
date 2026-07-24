import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// --- LOCAL DATABASE SERVICE ---
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('hydrodeck.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
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
  }

  // Historical Logs Queries
  Future<void> insertLog(HistoricalData log) async {
    final db = await instance.database;
    await db.insert('historical_logs', {
      'timestamp': log.timestamp.toIso8601String(),
      'pH': log.pH,
      'temperature': log.temperature,
      'waterLevel': log.waterLevel,
    });
  }

  Future<List<HistoricalData>> getLogs() async {
    final db = await instance.database;
    final result = await db.query('historical_logs', orderBy: 'timestamp DESC');
    return result.map((json) => HistoricalData(
      timestamp: DateTime.parse(json['timestamp'] as String),
      pH: json['pH'] as double,
      temperature: json['temperature'] as String,
      waterLevel: json['waterLevel'] as String,
    )).toList();
  }

  // Planting Runs History Queries
  Future<void> insertPlantingRecord(PlantingRecord record) async {
    final db = await instance.database;
    await db.insert('planting_history', {
      'batchNumber': record.batchNumber,
      'startDate': record.startDate.toIso8601String(),
      'endDate': record.endDate.toIso8601String(),
      'totalDays': record.totalDays,
    });
  }

  Future<List<PlantingRecord>> getPlantingHistory() async {
    final db = await instance.database;
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
    await db.insert(
      'active_session',
      {'id': 1, 'startDate': startDate.toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<DateTime?> getActiveSession() async {
    final db = await instance.database;
    final result = await db.query('active_session', where: 'id = ?', whereArgs: [1]);
    if (result.isNotEmpty) {
      return DateTime.parse(result.first['startDate'] as String);
    }
    return null;
  }

  Future<void> clearActiveSession() async {
    final db = await instance.database;
    await db.delete('active_session', where: 'id = ?', whereArgs: [1]);
  }
}

// --- NOTIFICATION SERVICE ---
class NotificationHelper {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings settings =
        InitializationSettings(android: androidSettings);

    await _notificationsPlugin.initialize(settings);

    // Request permissions for Android 13+
    _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> showPhAlertNotification(double ph) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'ph_alerts_channel',
      'pH Level Alerts',
      channelDescription: 'Notifications for critical pH level limits',
      importance: Importance.max,
      priority: Priority.high,
    );

    const NotificationDetails details = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      0,
      '⚠️ Critical pH Alert',
      'pH level has remained in critical range (${ph.toStringAsFixed(2)}) for over 20 seconds!',
      details,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationHelper.init();
  runApp(const HydrodeckApp());
}

class HydrodeckApp extends StatelessWidget {
  const HydrodeckApp({super.key});

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

// Data model representing captured historical snapshots
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

// Data model representing completed planting campaigns
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

// Gatekeeper widget to determine if the user is currently in an active session
class MainGatekeeper extends StatefulWidget {
  const MainGatekeeper({super.key});

  @override
  State<MainGatekeeper> createState() => _MainGatekeeperState();
}

class _MainGatekeeperState extends State<MainGatekeeper> {
  bool _isLoading = true;
  bool _isPlantingActive = false;
  DateTime? _plantingStartDate;
  List<PlantingRecord> _pastPlantingRuns = [];
  
  String _activeEsp32Ip = "hydrodeck.local";
  Timer? _autoConnectTimer;

  @override
  void initState() {
    super.initState();
    _loadStoredSessionAndData();
    _startAutoConnectionDiscovery();
  }

  @override
  void dispose() {
    _autoConnectTimer?.cancel();
    super.dispose();
  }

  // Load saved session state and historical batch records from DB
  Future<void> _loadStoredSessionAndData() async {
    final activeDate = await DatabaseHelper.instance.getActiveSession();
    final pastRuns = await DatabaseHelper.instance.getPlantingHistory();

    setState(() {
      _pastPlantingRuns = pastRuns;
      if (activeDate != null) {
        _plantingStartDate = activeDate;
        _isPlantingActive = true;
      }
      _isLoading = false;
    });
  }

  void _startAutoConnectionDiscovery() {
    final List<String> candidateHosts = [
      "hydrodeck.local",
      "192.168.1.100",
      "192.168.0.100",
      "10.0.2.2"
    ];

    _autoConnectTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      for (String host in candidateHosts) {
        try {
          final response = await http
              .get(Uri.parse('http://$host/status'))
              .timeout(const Duration(milliseconds: 1500));

          if (!mounted) return;

          if (response.statusCode == 200) {
            setState(() {
              _activeEsp32Ip = host;
            });
            break; 
          }
        } catch (_) {}
      }
    });
  }

  void _startPlanting() async {
    final now = DateTime.now();
    await DatabaseHelper.instance.saveActiveSession(now);

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

// --- START / WELCOME GATEWAY SCREEN ---
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
  
  // Storage for persistent last known values to retain data when offline
  String _lastValidWaterStatus = "low";
  String _lastValidWaterTemp = "25.0°C";
  double _lastValidPhValue = 7.00; 

  Timer? _realtimeTimer;
  Timer? _historicalLoggerTimer;

  // Historical Storage Array
  List<HistoricalData> _historyLogs = [];
  DateTime? _selectedFilterDate;

  // Active LED Pin toggles
  bool _led1On = false;
  bool _led2On = false;

  // Target Boundaries
  double _minPhThreshold = 5.5;
  double _maxPhThreshold = 6.8;

  // Critical pH Notification Tracking
  DateTime? _criticalPhStartTime;
  bool _notificationTriggeredForCurrentAlert = false;

  @override
  void initState() {
    super.initState();
    _esp32Ip = widget.initialIp;
    _ipController = TextEditingController(text: _esp32Ip);
    _loadStoredLogs();
    _startRealtimeMonitoring();
    _startHistoricalLogging();
  }

  @override
  void dispose() {
    _realtimeTimer?.cancel();
    _historicalLoggerTimer?.cancel();
    _ipController.dispose();
    super.dispose();
  }

  // Load existing logs from sqlite DB
  Future<void> _loadStoredLogs() async {
    final storedLogs = await DatabaseHelper.instance.getLogs();
    setState(() {
      _historyLogs = storedLogs;
    });
  }

  int _getElapsedPlantingDay(DateTime timestamp) {
    final startDay = DateTime(widget.startDate.year, widget.startDate.month, widget.startDate.day);
    final currentDay = DateTime(timestamp.year, timestamp.month, timestamp.day);
    return currentDay.difference(startDay).inDays + 1;
  }

  // Check critical pH duration and trigger Push Notification if exceeded (20 seconds testing)
  void _evaluatePhNotification(double ph) {
    bool isPhCritical = (ph < _minPhThreshold || ph > _maxPhThreshold);

    if (isPhCritical) {
      _criticalPhStartTime ??= DateTime.now();
      
      final elapsed = DateTime.now().difference(_criticalPhStartTime!).inSeconds;

      // Triggers if critical for 20 seconds or more (change to inMinutes >= 10 for production)
      if (elapsed >= 20 && !_notificationTriggeredForCurrentAlert) {
        NotificationHelper.showPhAlertNotification(ph);
        _notificationTriggeredForCurrentAlert = true;
      }
    } else {
      _criticalPhStartTime = null;
      _notificationTriggeredForCurrentAlert = false;
    }
  }

  // Poll real-time values using mDNS hostname or custom IP
  void _startRealtimeMonitoring() {
    _realtimeTimer = Timer.periodic(const Duration(milliseconds: 2000), (timer) async {
      final Uri url = Uri.parse('http://$_esp32Ip/status');
      try {
        final response = await http.get(url).timeout(const Duration(milliseconds: 2500));
        
        if (!mounted) return;

        if (response.statusCode == 200) {
          final Map<String, dynamic> data = jsonDecode(response.body);
          
          double currentPh = _lastValidPhValue;
          if (data['ph'] != null) {
            currentPh = (data['ph'] is num) ? (data['ph'] as num).toDouble() : 7.00;
          }

          _evaluatePhNotification(currentPh);

          setState(() {
            _connectionStatus = "Connected";
            _lastValidWaterStatus = data['water'] ?? 'low';
            
            if (data['temp'] != null && data['temp'] != 0.0) {
              _lastValidWaterTemp = "${data['temp']}°C";
            }
            _lastValidPhValue = currentPh;
          });
        } else {
          setState(() {
            _connectionStatus = "Disconnected";
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _connectionStatus = "Disconnected";
        });
      }
    });
  }

  void _startHistoricalLogging() {
    _historicalLoggerTimer = Timer.periodic(const Duration(seconds: 20), (timer) async {
      final newLog = HistoricalData(
        timestamp: DateTime.now(),
        pH: _lastValidPhValue,
        temperature: _lastValidWaterTemp,
        waterLevel: _getProcessedWaterStatus(),
      );

      await DatabaseHelper.instance.insertLog(newLog);

      if (!mounted) return;
      
      setState(() {
        _historyLogs.insert(0, newLog);
      });
    });
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

  // --- HOME SCREEN DESIGN ---
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

  // --- DATA HISTORICAL SCREEN ---
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

  // --- SETTINGS SCREEN DESIGN WITH END PLANTING ---
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
                    setState(() {
                      _esp32Ip = val.trim();
                    });
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

// --- SNAPSHOT DETAIL VIEW SCREEN ---
class SnapshotDetailScreen extends StatelessWidget {
  final HistoricalData data;
  final String formattedTime;
  const SnapshotDetailScreen({super.key, required this.data, required this.formattedTime});

  @override
  Widget build(BuildContext context) {
    bool isWaterFull = data.waterLevel == "Water full";

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
            _buildStaticGrid(isWaterFull),
            
            const SizedBox(height: 24),
            const Text('Grow Bed 2 (Historical Metrics)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _buildStaticGrid(isWaterFull),
          ],
        ),
      ),
    );
  }

  Widget _buildStaticGrid(bool isWaterFull) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildStaticCard('ACIDITY (PH)', '${data.pH.toStringAsFixed(2)} pH', 'Log Data')),
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