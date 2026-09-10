import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    throw UnsupportedError(
      'DefaultFirebaseOptions are not configured for this platform.',
    );
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyASj_UuzXUyOqOvMD4vuy9lscldry3gkuY',
    appId: '1:32937687187:web:22f9aaa583a18a47d43566',
    messagingSenderId: '32937687187',
    projectId: 'exam-44b',
    authDomain: 'exam-44b.firebaseapp.com',
    storageBucket: 'exam-44b.firebasestorage.app',
  );
}
