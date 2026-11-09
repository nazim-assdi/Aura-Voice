import 'package:flutter/material.dart';
import 'core/theme/aura_theme.dart';
import 'features/home/home_shell.dart';

class AuraVoiceApp extends StatelessWidget {
  const AuraVoiceApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Aura Voice AI',
        debugShowCheckedModeBanner: false,
        theme: AuraTheme.dark,
        home: const HomeShell(),
      );
}
