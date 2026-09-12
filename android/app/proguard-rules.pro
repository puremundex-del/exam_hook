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