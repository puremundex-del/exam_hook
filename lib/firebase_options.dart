import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

    class DefaultFirebaseOptions {
      static FirebaseOptions get currentPlatform {
          if (kIsWeb) {
                return web;
                    }
                        switch (defaultTargetPlatform) {
                              case TargetPlatform.android:
                                      return android;
                                            default:
                                                    throw UnsupportedError(
                                                              'DefaultFirebaseOptions are not configured for this platform.',
                                                                      );
                                                                          }
                                                                            }

                                                                              static const FirebaseOptions web = FirebaseOptions(
                                                                                  apiKey: 'AIzaSyASj_UuzXUyOqOvMD4vuy9lscldry3gkuY',
                                                                                      appId: '1:32937687187:web:22f9aaa583a18a47d43566',
                                                                                          messagingSenderId: '32937687187',
                                                                                              projectId: 'exam-44b',
                                                                                                  authDomain: 'exam-44b.firebaseapp.com',
                                                                                                      storageBucket: 'exam-44b.firebasestorage.app',
                                                                                                        );

                                                                                                          // ADD THIS: Use your Android app credentials from Firebase Console
                                                                                                            static const FirebaseOptions android = FirebaseOptions(
                                                                                                                apiKey: 'AIzaSyASj_UuzXUyOqOvMD4vuy9lscldry3gkuY', // same as web is fine
                                                                                                                    appId: '1:32937687187:android:7cd32460ebd3232fd43566', // IMPORTANT: get this from Firebase Console
                                                                                                                        messagingSenderId: '32937687187',
                                                                                                                            projectId: 'exam-44b',
                                                                                                                                storageBucket: 'exam-44b.firebasestorage.app',
                                                                                                                                  );
                                                                                                                                  }