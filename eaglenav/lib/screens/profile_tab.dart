import 'package:flutter/material.dart';
import '../services/tts_service.dart';

class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
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
            onChanged: (value) {
              if (value != null) {
                setState(() => colorBlindMode = value);
              }
            },
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
            value: avoidStairs,
            onChanged: (value) => setState(() => avoidStairs = value),
          ),

          SwitchListTile(
            title: const Text('Wheelchair Accessible Routes'),
            value: wheelchairAccessibleRoutes,
            onChanged: (value) {
              setState(() => wheelchairAccessibleRoutes = value);
            },
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
            value: audioHaptics,
            onChanged: (value) => setState(() => audioHaptics = value),
          ),

          SwitchListTile(
            title: const Text('Enable Rumble Haptics'),
            value: rumbleHaptics,
            onChanged: (value) => setState(() => rumbleHaptics = value),
          ),

          const SizedBox(height: 40),

          ElevatedButton.icon(
            onPressed: () async {
              await initTts();

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