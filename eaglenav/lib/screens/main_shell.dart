import 'package:flutter/material.dart';
import 'package:eaglenav/features/navigation/presentation/navigation_screen.dart';
import 'favorites_tab.dart';
import 'events_screen.dart';
import 'profile_tab.dart';
import 'emergency_tab.dart';
import 'cv_screen.dart'; // this is where CVisionScreen is

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = [
    NavigationScreen(),
    FavoritesTab(),
    EventsScreen(),
    ProfileTab(),
    EmergencyTab(),
  ];

  void _onItemTapped(int index) {
    if (index == 5) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const cv_screen()),
      );
      return;
    }
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedIndex],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: _onItemTapped,

          backgroundColor: const Color.fromARGB(255, 222, 182, 52), // gold
          indicatorColor: Colors.transparent, // remove pill if you want flat look

          height: 70, // 👈 controls overall bar height

          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(
                color: Colors.black,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              );
            }
            return const TextStyle(
              color: Colors.white,
              fontSize: 11,
            );
          }),

          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined, size: 24, color: Colors.white),
              selectedIcon: Icon(Icons.home, size: 30, color: Colors.black),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.star_border, size: 24, color: Colors.white),
              selectedIcon: Icon(Icons.star, size: 30, color: Colors.black),
              label: 'Favorites',
            ),
            NavigationDestination(
              icon: Icon(Icons.event_outlined, size: 24, color: Colors.white),
              selectedIcon: Icon(Icons.event, size: 30, color: Colors.black),
              label: 'Events',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline, size: 24, color: Colors.white),
              selectedIcon: Icon(Icons.person, size: 30, color: Colors.black),
              label: 'Profile',
            ),
            NavigationDestination(
              icon: Icon(Icons.warning_amber_outlined, size: 24, color: Colors.white),
              selectedIcon: Icon(Icons.warning, size: 30, color: Colors.red),
              label: 'Emergency',
            ),
            NavigationDestination(
              icon: Icon(Icons.visibility_outlined, size: 24, color: Colors.white),
              selectedIcon: Icon(Icons.visibility, size: 30, color: Colors.black),
              label: 'CV',
            ),
          ],
        ),
    );
  }
}