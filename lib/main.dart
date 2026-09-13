import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';

import 'firebase_options.dart';
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';

const String supabaseUrl = 'https://fvcstahmzrfxptgeznuk.supabase.co';
const String supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ2Y3N0YWhtenJmeHB0Z2V6bnVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg2NTU5MDgsImV4cCI6MjEwNDIzMTkwOH0.qBpJhFV4g9obK3RZF2IdbE1AvWozdFLZ5KUvDvuijNw';

const String geminiApiKey = String.fromEnvironment(
  'GEMINI_API_KEY',
  defaultValue: '',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    if (kDebugMode) {
      debugPrint('Flutter Error: ${details.exception}');
      debugPrintStack(stackTrace: details.stack);
    }
  };

  Object? firebaseInitializationError;

  // Firebase is required by the main resource screens.
  try {
    if (Firebase.apps.isEmpty) {
      try {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      } catch (e) {
        // If generated Firebase options are unavailable/mismatched, allow the
        // native Android Firebase configuration to initialize Firebase.
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp();
        } else {
          rethrow;
        }
      }
    }
  } catch (e, stackTrace) {
    firebaseInitializationError = e;
    debugPrint('Firebase initialization error: $e');
    if (kDebugMode) {
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  // Supabase is used for uploads/admin storage. It must not prevent the main
  // ExamHook application from opening if its initialization fails.
  try {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseKey,
      debug: kDebugMode,
    );
  } catch (e, stackTrace) {
    debugPrint('Supabase initialization error: $e');
    if (kDebugMode) {
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: ExamHookApp(
        initializationError: firebaseInitializationError,
      ),
    ),
  );
}

class ExamHookApp extends StatelessWidget {
  final Object? initializationError;

  const ExamHookApp({super.key, this.initializationError});

  @override
  Widget build(BuildContext context) {
    final ThemeProvider themeProvider = Provider.of<ThemeProvider>(context);

    const Color primaryGreen = Color(0xFF00C896);
    const Color secondaryBlue = Color(0xFF3B82F6);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ExamHook',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryGreen,
          secondary: secondaryBlue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.poppinsTextTheme(),
        appBarTheme: AppBarTheme(
          backgroundColor: primaryGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: GoogleFonts.poppins(
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 14,
            ),
          ),
        ),
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 2,
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryGreen,
          secondary: secondaryBlue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.poppinsTextTheme(
          ThemeData.dark().textTheme,
        ),
      ),
      themeMode: themeProvider.themeMode,
      home: initializationError == null
          ? SplashScreen(geminiApiKey: geminiApiKey)
          : StartupErrorScreen(error: initializationError!),
    );
  }
}

class StartupErrorScreen extends StatelessWidget {
  final Object error;

  const StartupErrorScreen({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 56,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Unable to start the app',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  kDebugMode
                      ? '$error'
                      : 'Firebase could not be initialized. Check the Android Firebase configuration.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
