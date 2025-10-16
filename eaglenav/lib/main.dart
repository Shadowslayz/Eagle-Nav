import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_tts/flutter_tts.dart';

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
    // Initialize geolocator - request permissions if needed
    _geolocatorInitialized = true;
    print('Geolocator initialized');
  } catch (e) {
    print('Geolocator init error: $e');
  }
}

void main() {
  // Note: No async here so app starts immediately
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const EagleNavApp(),
  ); // use const for more efficient memory performance

  // Defer ALL heavy initialization to 2 seconds after app starts
  // This avoids crash on startup due to too much work on main thread
  Future.delayed(const Duration(seconds: 2), () {
    initNotifications();
  });
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
    NotificationsScreen(),
    ProfileScreen(),
    EmergencyScreen(),
  ];

  void _onItemTapped(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(60.0),
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
        unselectedItemColor: const Color.fromARGB(255, 255, 255, 255),
        selectedIconTheme: const IconThemeData(size: 30),
        unselectedIconTheme: const IconThemeData(size: 24),
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.star), label: 'Favorites'),
          BottomNavigationBarItem(
            icon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
          BottomNavigationBarItem(
            icon: Icon(Icons.warning, color: Colors.red),
            label: 'Emergency',
          ),
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
                  MaterialPageRoute(
                    builder: (context) => const MapTestScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.map_rounded),
              label: const Text('Start Route (Map Test)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 161, 133, 40),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
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
          interactionOptions: InteractionOptions(
            flags: InteractiveFlag.drag | InteractiveFlag.pinchZoom,
          ),
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
      child: Text(
        'Favorites Screen (Bookmarks)',
        style: TextStyle(fontSize: 18),
      ),
    );
  }
}

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Notifications Screen (Events/Alerts)',
        style: TextStyle(fontSize: 18),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool voiceGuidance = true;
  bool highContrast = false;
  bool audioHaptics = true;
  bool rumbleHaptics = false;

  bool aroundPeople = true;
  String colorBlindMode = 'None';
  double colorBlindIntensity = 0.5;
  bool announceObstacles = true;
  bool announceLandmarks = true;
  bool announcePeople = false;

  bool avoidStairs = true;
  bool wheelchairAccessibleRoutes = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accessibility Settings'),
        backgroundColor: const Color.fromARGB(255, 161, 133, 40),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          const Text(
            'Display Settings',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            title: const Text('High Contrast Mode'),
            value: highContrast,
            onChanged: (value) => setState(() => highContrast = value),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: colorBlindMode,
            decoration: const InputDecoration(
              labelText: 'Color Blind Mode',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'None', child: Text('None')),
              DropdownMenuItem(
                value: 'Protanopia',
                child: Text('Protanopia (Red-Blind)'),
              ),
              DropdownMenuItem(
                value: 'Protanomaly',
                child: Text('Protanomaly (Weak Red)'),
              ),
              DropdownMenuItem(
                value: 'Deuteranopia',
                child: Text('Deuteranopia (Green-Blind)'),
              ),
              DropdownMenuItem(
                value: 'Deuteranomaly',
                child: Text('Deuteranomaly (Weak Green)'),
              ),
              DropdownMenuItem(
                value: 'Tritanopia',
                child: Text('Tritanopia (Blue-Blind)'),
              ),
              DropdownMenuItem(
                value: 'Tritanomaly',
                child: Text('Tritanomaly (Weak Blue)'),
              ),
              DropdownMenuItem(
                value: 'Achromatopsia',
                child: Text('Achromatopsia (No Color)'),
              ),
            ],
            onChanged: (value) => setState(() => colorBlindMode = value!),
          ),
          const SizedBox(height: 20),
          Text(
            'Color Blindness Intensity: ${(colorBlindIntensity * 100).round()}%',
            style: const TextStyle(fontSize: 16),
          ),
          Slider(
            value: colorBlindIntensity,
            onChanged: colorBlindMode == 'None'
                ? null
                : (value) => setState(() => colorBlindIntensity = value),
            min: 0.0,
            max: 1.0,
            divisions: 10,
            activeColor: const Color.fromARGB(255, 161, 133, 40),
          ),
          const Divider(height: 40),
          const Text(
            'Navigation Preferences',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            title: const Text('Navigate Around People'),
            subtitle: const Text('Avoid crowds when generating routes'),
            value: aroundPeople,
            onChanged: (value) => setState(() => aroundPeople = value),
          ),
          const Divider(height: 40),
          const Text(
            'Accessibility Needs',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            title: const Text('Avoid Stairs'),
            subtitle: const Text('Use ramps or elevators instead of stairs'),
            value: avoidStairs,
            onChanged: (value) => setState(() => avoidStairs = value),
          ),
          SwitchListTile(
            title: const Text('Wheelchair Accessible Routes'),
            subtitle: const Text('Use verified accessible paths only'),
            value: wheelchairAccessibleRoutes,
            onChanged: (value) =>
                setState(() => wheelchairAccessibleRoutes = value),
          ),
          const Divider(height: 40),
          const Text(
            'TTS Announcements',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            title: const Text('Enable Voice Guidance'),
            value: voiceGuidance,
            onChanged: (value) => setState(() => voiceGuidance = value),
          ),
          SwitchListTile(
            title: const Text('Announce Obstacles'),
            value: announceObstacles,
            onChanged: (value) => setState(() => announceObstacles = value),
          ),
          SwitchListTile(
            title: const Text('Announce Landmarks'),
            value: announceLandmarks,
            onChanged: (value) => setState(() => announceLandmarks = value),
          ),
          SwitchListTile(
            title: const Text('Announce Nearby People'),
            value: announcePeople,
            onChanged: (value) => setState(() => announcePeople = value),
          ),
          const Divider(height: 40),
          const Text(
            'Haptic Feedback',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            title: const Text('Enable Audio Haptics'),
            subtitle: const Text('Subtle vibration synced with sound cues'),
            value: audioHaptics,
            onChanged: (value) => setState(() => audioHaptics = value),
          ),
          SwitchListTile(
            title: const Text('Enable Rumble Haptics'),
            subtitle: const Text('Stronger feedback for warnings or turns'),
            value: rumbleHaptics,
            onChanged: (value) => setState(() => rumbleHaptics = value),
          ),
          const SizedBox(height: 40),
          ElevatedButton.icon(
            onPressed: () async {
              // Initialize TTS if needed before speaking
              await initTts();
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Settings saved')));
            },
            icon: const Icon(Icons.save),
            label: const Text('Save Settings'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color.fromARGB(255, 161, 133, 40),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
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
        icon: Icon(Icons.warning, color: Colors.white),
        label: Text("Contact Security", style: TextStyle(color: Colors.white)),
        onPressed: () {
          // TODO: Emergency call/alert
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text("Emergency tapped")));
        },
      ),
    );
  }
}

Future<void> initNotifications() async {
  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('America/Los_Angeles'));

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await fln.initialize(initSettings);
}

Future<void> scheduleDayBefore(
  String id,
  String title,
  String startDateIso,
) async {
  final parts = startDateIso.split('-').map(int.parse).toList();
  final eventDate = DateTime(parts[0], parts[1], parts[2], 9);
  final notifyTime = eventDate.subtract(const Duration(days: 1));
  if (notifyTime.isBefore(DateTime.now())) return;

  final when = tz.TZDateTime.from(notifyTime, tz.local);
  const android = AndroidNotificationDetails(
    'eaglenav_events',
    'Event Reminders',
    channelDescription: 'Notifies you the day before bookmarked events',
    importance: Importance.high,
    priority: Priority.high,
  );

  await fln.zonedSchedule(
    id.hashCode,
    'Event tomorrow: $title',
    'Happening on $startDateIso',
    when,
    const NotificationDetails(android: android),
    uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.dateAndTime,
  );
}

Future<void> cancelReminder(String id) async {
  await fln.cancel(id.hashCode);
}
