import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/services/file_service.dart';
import 'core/services/obd_service.dart';
import 'core/services/storage_service.dart';
import 'core/theme/app_theme.dart';
import 'state/app_state.dart';
import 'state/obd_provider.dart';
import 'state/profile_provider.dart';
import 'state/trip_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrintStack(stackTrace: details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Unhandled asynchronous error: $error');
    debugPrintStack(stackTrace: stack);
    return true;
  };

  // Show the splash screen immediately while services boot up.
  runApp(const _SplashApp());

  try {
    final storage = StorageService();
    await storage.init();
    final fileService = FileService();

    final profileProvider = ProfileProvider(storage);
    await profileProvider.loadProfiles();
    final tripProvider = TripProvider(fileService, storage);
    await tripProvider.loadTrips();
    final obdProvider = ObdProvider(ObdService(storage));

    final appState = AppState(
      profiles: profileProvider,
      obd: obdProvider,
      trips: tripProvider,
    );

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ProfileProvider>(
            create: (_) => profileProvider,
          ),
          ChangeNotifierProvider<ObdProvider>(
            create: (_) => obdProvider,
          ),
          ChangeNotifierProvider<TripProvider>(
            create: (_) => tripProvider,
          ),
          Provider<AppState>.value(value: appState),
        ],
        child: const FuelApp(),
      ),
    );
  } catch (error, stack) {
    debugPrint('App bootstrap failed: $error');
    debugPrintStack(stackTrace: stack);
    runApp(_StartupErrorApp(error: error));
  }
}

class _SplashApp extends StatelessWidget {
  const _SplashApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const _SplashScreen(),
    );
  }
}

class _SplashScreen extends StatefulWidget {
  const _SplashScreen();

  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..forward();

  late final Animation<double> _fadeIn = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
  );

  late final Animation<double> _scale = Tween<double>(
    begin: 0.8,
    end: 1.0,
  ).animate(CurvedAnimation(
    parent: _ctrl,
    curve: Curves.elasticOut,
  ));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surfaceDark,
      body: Center(
        child: FadeTransition(
          opacity: _fadeIn,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.accentCyan, AppTheme.accentViolet],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.accentCyan.withValues(alpha: 0.35),
                        blurRadius: 32,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.local_gas_station,
                    color: Colors.black,
                    size: 48,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Fuel Trip Tracker',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Initializing...',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 36),
                SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(
                    backgroundColor: AppTheme.surfaceDarkOutline,
                    valueColor: AlwaysStoppedAnimation(
                      AppTheme.accentCyan.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        backgroundColor: AppTheme.surfaceDark,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: AppTheme.accentMagenta,
                  size: 64,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Failed to initialize',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
