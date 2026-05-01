import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/user_tier_provider.dart';
import 'screens/home_screen.dart';
import 'theme/lightwhisper_theme_v2.dart';

class LightWhisperApp extends StatelessWidget {
  const LightWhisperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => UserTierProvider(isProUser: true),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'LightWhisper',
        theme: buildLightwhisperTheme(),
        home: const HomeScreen(),
      ),
    );
  }
}
