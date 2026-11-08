# 桃花源闪退修复（2026-11-09）：v2 包的 dex 里一个 Activity 子类都不剩，
# Manifest 指的 dev.akash.skystream.MainActivity 在包里不存在，R8 把真正的
# MainActivity 连带 FlutterActivity 链一并削掉了。显式 keep 住入口类。
# Flutter Gradle 插件在 shrink 开启时会自动把 android/app/proguard-rules.pro
# 加进 proguardFiles（FlutterPlugin.kt），不用改 build.gradle.kts。
-keep class dev.akash.skystream.MainActivity { *; }
-keep class io.flutter.embedding.android.FlutterActivity { *; }
