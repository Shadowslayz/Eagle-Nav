import 'package:flutter/material.dart';
import 'screens/main_shell.dart';

const Color csulGold = Color(0xFFC9A227);
const Color csulaDark = Color(0xFF1A1A1A);

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
        colorScheme: ColorScheme.fromSeed(
          seedColor: csulGold,
          primary: csulGold,
          onPrimary: Colors.black,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: csulaDark,
          foregroundColor: Colors.white,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
          iconTheme: IconThemeData(color: csulGold),
          elevation: 0,
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return csulGold;
            return Colors.grey;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return csulGold.withOpacity(0.4);
            return Colors.grey.withOpacity(0.3);
          }),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: csulGold,
          thumbColor: csulGold,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          color: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: csulGold,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        dividerTheme: DividerThemeData(color: Colors.grey.shade200),
      ),
      home: const MainShell(),
    );
  }
}
