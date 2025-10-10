import 'package:flutter/material.dart';

void main() {
  runApp(EagleNavApp());
}

class EagleNavApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Eagle Nav',
      theme: ThemeData(
        brightness: Brightness.light,
        primaryColor: const Color.fromARGB(255, 161, 133, 40),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 16.0),
        ),
      ),
      home: MainLayout(),
    );
  }
}

class MainLayout extends StatefulWidget {
  @override
  _MainLayoutState createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _selectedIndex = 0;

  // Screens for bottom nav
  final List<Widget> _screens = [
    HomeScreen(),
    FavoritesScreen(),
    NotificationsScreen(),
    ProfileScreen(),
    EmergencyScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(60.0),
        child: AppBar(
          backgroundColor: Color.fromARGB(255, 222, 182, 52),
          elevation: 4,
          title: SearchBarWidget(),
          centerTitle: true,
        ),
      ),
      body: _screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color.fromARGB(255, 222, 182, 52),        // 🟡 Set background color
        selectedItemColor: Colors.black,      // ⚫ Selected icon/text color
        unselectedItemColor: const Color.fromARGB(255, 255, 255, 255),    // ⚪ Unselected icon/text color
        selectedIconTheme: IconThemeData(size: 30),
        unselectedIconTheme: IconThemeData(size: 24),
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.star),
            label: 'Favorites',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profile',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.warning, color: Colors.red),
            label: 'Emergency',
          ),
        ],
      ),
    );
  }
}

// 🔍 Search Bar Widget
class SearchBarWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          // 🖼️ Logo on the left
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Image.asset(
              'assets/images/DarkSimplifiedEagleIcon.png', // make sure this path is correct
              height: 28,
              width: 28,
            ),
          ),

          // 🔍 Text field area
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search destination...',
                border: InputBorder.none,
              ),
            ),
          ),

          // 🎤 Mic icon button
          IconButton(
            icon: Icon(Icons.mic, color: Colors.amber),
            onPressed: () {
              // TODO: Voice input logic
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Voice search tapped")),
              );
            },
          ),
        ],
      ),
    );
  }
}

// 📱 Placeholder Screens
class HomeScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('Home Screen (Map/AR here)', style: TextStyle(fontSize: 18)),
    );
  }
}

class FavoritesScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('Favorites Screen (Bookmarks)', style: TextStyle(fontSize: 18)),
    );
  }
}

class NotificationsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('Notifications Screen (Events/Alerts)', style: TextStyle(fontSize: 18)),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // Accessibility Settings
  bool voiceGuidance = true;
  bool highContrast = false;
  bool audioHaptics = true;
  bool rumbleHaptics = false;

  // Navigation & Announcements
  bool aroundPeople = true; // true = avoid crowds, false = go through
  String colorBlindMode = 'None';
  double colorBlindIntensity = 0.5; // slider for severity
  bool announceObstacles = true;
  bool announceLandmarks = true;
  bool announcePeople = false;

  // Accessibility Needs
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
          /// --- DISPLAY SETTINGS ---
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
              DropdownMenuItem(value: 'Protanopia', child: Text('Protanopia (Red-Blind)')),
              DropdownMenuItem(value: 'Protanomaly', child: Text('Protanomaly (Weak Red)')),
              DropdownMenuItem(value: 'Deuteranopia', child: Text('Deuteranopia (Green-Blind)')),
              DropdownMenuItem(value: 'Deuteranomaly', child: Text('Deuteranomaly (Weak Green)')),
              DropdownMenuItem(value: 'Tritanopia', child: Text('Tritanopia (Blue-Blind)')),
              DropdownMenuItem(value: 'Tritanomaly', child: Text('Tritanomaly (Weak Blue)')),
              DropdownMenuItem(value: 'Achromatopsia', child: Text('Achromatopsia (No Color)')),
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

          /// --- NAVIGATION SETTINGS ---
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

          /// --- ACCESSIBILITY NEEDS ---
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
            onChanged: (value) => setState(() => wheelchairAccessibleRoutes = value),
          ),

          const Divider(height: 40),

          /// --- TTS ANNOUNCEMENTS ---
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

          /// --- HAPTIC FEEDBACK ---
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
            onPressed: () {
              // TODO: Save preferences via SharedPreferences or database
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Settings saved')),
              );
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
  @override
  Widget build(BuildContext context) {
    return Center(
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
        icon: Icon(Icons.warning, color: Colors.white),
        label: Text("Contact Security", style: TextStyle(color: Colors.white)),
        onPressed: () {
          // TODO: Emergency call/alert
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Emergency tapped")),
          );
        },
      ),
    );
  }
}
