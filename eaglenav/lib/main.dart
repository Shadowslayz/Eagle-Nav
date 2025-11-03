import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'screens/events_screen.dart';

final FlutterLocalNotificationsPlugin fln = FlutterLocalNotificationsPlugin();
final FlutterTts flutterTts = FlutterTts();

bool _ttsInitialized = false;
bool _geolocatorInitialized = false;

Future<void> initTts() async {
  if (_ttsInitialized) return;
  try {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setPitch(1.0);
    _ttsInitialized = true;
    print('TTS initialized');
  } catch (e) {
    print('TTS init error: $e');
  }
}

Future<void> initGeolocator() async {
  if (_geolocatorInitialized) return;
  try {
    _geolocatorInitialized = true;
    print('Geolocator initialized');
  } catch (e) {
    print('Geolocator init error: $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications(); // ✅ initialize before runApp
  runApp(const EagleNavApp());
}

class EagleNavApp extends StatelessWidget {
  const EagleNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eagle Nav',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        primaryColor: const Color.fromARGB(255, 161, 133, 40),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 16.0)),
      ),
      home: const MainLayout(),
    );
  }
}

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _selectedIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    FavoritesScreen(),
    EventsScreen(),
    ProfileScreen(),
    EmergencyScreen(),
  ];

  void _onItemTapped(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60.0),
        child: AppBar(
          backgroundColor: const Color.fromARGB(255, 222, 182, 52),
          elevation: 4,
          title: const SearchBarWidget(),
          centerTitle: true,
        ),
      ),
      body: IndexedStack(index: _selectedIndex, children: _screens),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color.fromARGB(255, 222, 182, 52),
        selectedItemColor: Colors.black,
        unselectedItemColor: Colors.white,
        selectedIconTheme: const IconThemeData(size: 30),
        unselectedIconTheme: const IconThemeData(size: 24),
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.star), label: 'Favorites'),
          BottomNavigationBarItem(
              icon: Icon(Icons.notifications), label: 'Alerts/Events'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
          BottomNavigationBarItem(
              icon: Icon(Icons.warning, color: Colors.red), label: 'Emergency'),
        ],
      ),
    );
  }
}

class SearchBarWidget extends StatelessWidget {
  const SearchBarWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Image.asset(
              'assets/images/DarkSimplifiedEagleIcon.png',
              height: 28,
              width: 28,
            ),
          ),
          const Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search destination...',
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.mic, color: Colors.amber),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Voice search tapped")),
              );
            },
          ),
        ],
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EagleNav Home'),
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Home Screen\n(Map / AR will appear here)',
              style: TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const MapTestScreen()),
                );
              },
              icon: const Icon(Icons.map_rounded),
              label: const Text('Start Route (Map Test)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 161, 133, 40),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MapTestScreen extends StatelessWidget {
  const MapTestScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map Test Mode'),
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
      ),
      body: const RepaintBoundary(child: SimpleMap()),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Map test started! (Simulating route setup...)'),
              duration: Duration(seconds: 2),
            ),
          );
        },
        child: const Icon(Icons.play_arrow_rounded),
      ),
    );
  }
}

class SimpleMap extends StatefulWidget {
  const SimpleMap({super.key});

  @override
  State<SimpleMap> createState() => _SimpleMapState();
}

class _SimpleMapState extends State<SimpleMap> {
  late MapController mapController;

  @override
  void initState() {
    super.initState();
    mapController = MapController();
  }

  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: FlutterMap(
        mapController: mapController,
        options: const MapOptions(
          initialCenter: LatLng(34.067, -118.170),
          initialZoom: 16.0,
          interactionOptions:
              InteractionOptions(flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.eagle_nav_app',
            maxZoom: 18.0,
            minZoom: 12.0,
          ),
        ],
      ),
    );
  }
}

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Favorites Screen (Bookmarks)', style: TextStyle(fontSize: 18)),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Profile Screen Placeholder')),
    );
  }
}

class EmergencyScreen extends StatelessWidget {
  const EmergencyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
        icon: const Icon(Icons.warning, color: Colors.white),
        label: const Text("Contact Security",
            style: TextStyle(color: Colors.white)),
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Emergency tapped")));
        },
      ),
    );
  }
}

// -------------------- NOTIFICATION LOGIC --------------------

Future<void> initNotifications() async {
  try {
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('America/Los_Angeles'));
  } catch (e) {
    debugPrint('TZ init error: $e');
  }

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);
  await fln.initialize(initSettings);

  final androidImpl =
      fln.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.requestNotificationsPermission();

  if (Platform.isAndroid) {
    await androidImpl?.requestExactAlarmsPermission(); // safe no-op on older
  }

  final iosImpl =
      fln.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
  await iosImpl?.requestPermissions(alert: true, badge: true, sound: true);
}

Future<void> scheduleDayBefore(String id, String title, String startDateIso) async {
  try {
    final parts = startDateIso.split('-').map(int.parse).toList();
    if (parts.length < 3) return;

    final eventDate = DateTime(parts[0], parts[1], parts[2], 9);
    final notifyTime = eventDate.subtract(const Duration(days: 1));
    if (notifyTime.isBefore(DateTime.now())) return;

    final when = tz.TZDateTime.from(notifyTime, tz.local);

    const androidDetails = AndroidNotificationDetails(
      'eaglenav_events',
      'Event Reminders',
      channelDescription: 'Notifies you the day before bookmarked events',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    // 🟢 Try exact/inexact schedule first
    await fln.zonedSchedule(
      id.hashCode,
      'Event tomorrow: $title',
      'Happening on $startDateIso',
      when,
      details,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.dateAndTime,
    );
  } catch (e) {
    debugPrint('⚠️ scheduleDayBefore failed: $e');

    // 🔁 Fallback: show notification immediately (not scheduled)
    const fallbackDetails = AndroidNotificationDetails(
      'eaglenav_fallback',
      'Fallback Notifications',
      channelDescription: 'Used when scheduling fails',
      importance: Importance.high,
      priority: Priority.high,
    );
    await fln.show(
      id.hashCode,
      'Reminder saved: $title',
      'Event reminder could not be scheduled (exact alarms not allowed)',
      const NotificationDetails(android: fallbackDetails),
    );
  }
}

Future<void> scheduleOnDay(
  String id,
  String title,
  String startDateIso, {
  int hour = 9,
}) async {
  try {
    final parts = startDateIso.split('-').map(int.parse).toList();
    if (parts.length < 3) return;

    final notifyTime = DateTime(parts[0], parts[1], parts[2], hour);
    if (notifyTime.isBefore(DateTime.now())) return;

    final when = tz.TZDateTime.from(notifyTime, tz.local);

    const androidDetails = AndroidNotificationDetails(
      'eaglenav_events',
      'Event Reminders',
      channelDescription: 'Notifies you for bookmarked events',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await fln.zonedSchedule(
      id.hashCode,
      'Today: $title',
      'Happening on $startDateIso',
      when,
      details,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.dateAndTime,
    );
  } catch (e) {
    debugPrint('⚠️ scheduleOnDay failed: $e');

    // 🔁 Fallback: show instant notification if scheduling fails
    const fallbackDetails = AndroidNotificationDetails(
      'eaglenav_fallback',
      'Fallback Notifications',
      channelDescription: 'Used when scheduling fails',
      importance: Importance.high,
      priority: Priority.high,
    );
    await fln.show(
      id.hashCode,
      'Reminder saved: $title',
      'Exact alarms not permitted — fallback triggered',
      const NotificationDetails(android: fallbackDetails),
    );
  }
}


Future<void> cancelReminder(String id) async {
  try {
    await fln.cancel(id.hashCode);
  } catch (e) {
    debugPrint('cancelReminder error: $e');
  }
}
