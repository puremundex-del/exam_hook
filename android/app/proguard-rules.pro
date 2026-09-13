# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Google Generative AI / Guava fix for AnnotatedType
-dontwarn com.google.common.**
-keep class com.google.common.** { *; }
-keep class com.google.gson.** { *; }
-dontwarn java.lang.reflect.**
-keep class java.lang.reflect.** { *; }

-keepattributes *Annotation*, InnerClasses, EnclosingMethod
# NEW: Fix for Play Core / SplitInstall
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }
-keep interface com.google.android.play.core.** { *; }
# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**