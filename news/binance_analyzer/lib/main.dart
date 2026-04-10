import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/backend_api_service.dart';
import 'services/notification_service.dart';
import 'screens/main_nav_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.binanceDark,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  await NotificationService.instance.initialize();
  await BackendApiService.initialize();

  runApp(const BinanceAnalyzerApp());
}

class BinanceAnalyzerApp extends StatelessWidget {
  const BinanceAnalyzerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '币安自选分析',
      theme: AppTheme.darkTheme,
      home: const MainNavScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
