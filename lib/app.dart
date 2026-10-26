import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

class MyVpnApp extends StatelessWidget {
  const MyVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My VPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF3B82F6),
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}
