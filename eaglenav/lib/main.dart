import 'package:flutter/material.dart';
import 'screens/main_shell.dart';

void main() {
  runApp(const EagleNavApp());
}

class EagleNavApp extends StatelessWidget {
  const EagleNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EagleNav',
      theme: ThemeData(
        useMaterial3: true,
      ),
      home: const MainShell(),
    );
  }
}