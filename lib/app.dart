import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/user_tier_provider.dart';
import 'screens/home_screen.dart';

class LightWhisperApp extends StatelessWidget {
  const LightWhisperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => UserTierProvider(isProUser: true),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'LightWhisper',
        theme: ThemeData.dark(useMaterial3: true),
        home: const HomeScreen(),
      ),
    );
  }
}
