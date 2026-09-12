import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'firebase_options.dart'; // <-- IMPORTANT: this was missing
import 'providers/theme_provider.dart';
import 'screens/splash_screen.dart';

// 1. READ KEYS FROM --dart-define
const supabaseUrl = 'https://fvcstahmzrfxptgeznuk.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ2Y3N0YWhtenJmeHB0Z2V6bnVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg2NTU5MDgsImV4cCI6MjEwNDIzMTkwOH0.qBpJhFV4g9obK3RZF2IdbE1AvWozdFLZ5KUvDvuijNw';
const geminiApiKey = String.fromEnvironment('GEMINI_API_KEY'); // <-- ADDED

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep startup errors from leaving the release build on a blank screen.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    if (kDebugMode) {
      debugPrint('Flutter Error: ${details.exception}');
      debugPrintStack(stackTrace: details.stack);
    }
  };

  Object? initializationError;

  try {
    // 1. Check Gemini Key first
    if (geminiApiKey.isEmpty) {
      throw Exception("GEMINI_API_KEY is missing. Build with --dart-define=GEMINI_API_KEY=your_key");
    }

    // 2. Initialize Firebase with the generated platform config.
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // 3. Initialize Supabase.
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseKey,
      debug: kDebugMode,
    );
  } catch (e, stackTrace) {
    initializationError = e;
    if (kDebugMode) {
      debugPrint('Initialization error: $e');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: ExamHookApp(
        initializationError: initializationError,
        geminiApiKey: geminiApiKey, // <-- ADDED: pass key down
      ),
    ),
  );
}

class ExamHookApp extends StatelessWidget {
  final Object? initializationError;
  final String geminiApiKey; // <-- ADDED

  const ExamHookApp({
    super.key, 
    this.initializationError,
    required this.geminiApiKey, // <-- ADDED
  });

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    // Pro Green + Blue Theme as you requested
    const Color primaryGreen = Color(0xFF00C896); // Mint Green
    const Color secondaryBlue = Color(0xFF3B82F6); // Pro Blue

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
          titleTextStyle: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          ),
        ),
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
        textTheme: GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme),
      ),
      themeMode: themeProvider.themeMode,
      home: initializationError == null
          ? SplashScreen(geminiApiKey: geminiApiKey) // <-- ADDED: pass to splash/home
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
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Unable to start the app',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                kDebugMode ? '$error' : 'Please restart the app and try again.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}