import 'package:flutter/material.dart';

class ThemeProvider with ChangeNotifier {
  Color _primaryColor = const Color(0xFF00C896); // ExamHook Green
  Color get primaryColor => _primaryColor; // <-- THIS WAS MISSING

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  void toggleTheme() {
    _themeMode = _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }
}
