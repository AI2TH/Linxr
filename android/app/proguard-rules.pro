# ProGuard / R8 rules for Linxr.
#
# In addition to the release build (minifyEnabled true), we enable R8 on debug
# builds to remove references to API 33+ classes (android.window.OnBackAnimationCallback)
# that cause Dalvik/ART class verification failures on pre-API-33 devices like
# LDPlayer (Android 9 / API 28). See NEW-12 in CHANGELOG.md.

# Keep MainActivity so the launcher can find it.
-keep class com.ai2th.linxr.MainActivity { *; }
-keep class com.ai2th.linxr.AlpineApp { *; }
-keep class com.ai2th.linxr.VmService { *; }

# Keep Flutter classes.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }

# Keep method channels for Dart<->Kotlin bridge.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# NEW-12: Don't warn about API 33+ classes that are only used by predictive-back
# gesture code paths. R8 will still keep the references but the build will succeed.
-dontwarn android.window.OnBackAnimationCallback
-dontwarn android.window.OnBackInvokedCallback
-dontwarn android.window.OnBackInvokedDispatcher
-dontwarn android.window.BackEvent

# Allow R8 to remove unused AndroidX activity 1.8.x predictive-back code paths.
-assumenosideeffects class androidx.activity.ComponentActivity {
    public *** onBackInvoked();
}

# Strip debug logs from release builds.
-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
}

# Keep our own Kotlin classes.
-keep class com.ai2th.linxr.** { *; }

