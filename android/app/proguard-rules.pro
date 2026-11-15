# WireGuard — احتفظ بكل شيء لأنها تستخدم Reflection
-keep class com.wireguard.** { *; }
-keepclassmembers class com.wireguard.** { *; }
-dontwarn com.wireguard.**

# Kotlin Coroutines
-keepclassmembers class kotlinx.coroutines.** { *; }
-keep class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**

# Flutter Engine
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.**

# منع تحذيرات شائعة
-dontwarn org.jetbrains.**
-dontwarn javax.annotation.**
-dontwarn kotlin.**

# الحفاظ على أسماء Native Methods
-keepclasseswithmembernames class * {
    native <methods>;
}
