# Reglas ProGuard para Oir Pro (antes "PSK Hearing Aid")
# Spec: oir-pro-rebrand-harden-and-remote-config (Fase 2)
#
# Estrategia: minimizar superficie reverso engineering renombrando todo
# lo que NO sea consumido por reflection o JNI. Las reglas que siguen
# preservan exactamente esos puntos de entrada externos al dex.

# ---------------------------------------------------------------------
# JNI nativos - imprescindible
# ---------------------------------------------------------------------
# Cualquier metodo native debe mantener su nombre exacto para que el
# linker dinamico de Android lo asocie con el simbolo en .so.
-keepclasseswithmembernames class * {
    native <methods>;
}

# Clases del package del proyecto que tienen JNI o callbacks de Oboe.
-keep class com.psk.hearing_aid_app.** { *; }

# ---------------------------------------------------------------------
# Google Oboe (audio callbacks)
# ---------------------------------------------------------------------
-keep class com.google.oboe.** { *; }

# ---------------------------------------------------------------------
# Flutter embedding y plugins
# ---------------------------------------------------------------------
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }

# Flutter Bluetooth Low Energy
-keep class com.lib.flutter_blue_plus.** { *; }

# Audio plugins
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.ryanheise.audio_session.** { *; }

# permission_handler
-keep class com.baseflow.permissionhandler.** { *; }

# wakelock_plus
-keep class dev.fluttercommunity.plus.wakelock.** { *; }

# url_launcher
-keep class io.flutter.plugins.urllauncher.** { *; }

# share_plus (export del diagnóstico DSP vía share sheet). Sin este keep,
# R8 en release recorta/renombra el plugin y su ShareFileProvider, y
# Share.shareXFiles lanza excepción en runtime → "Error al exportar".
# (En debug no se nota porque R8 no corre.)
-keep class dev.fluttercommunity.plus.share.** { *; }

# flutter_tts
-keep class com.tundralabs.fluttertts.** { *; }

# ---------------------------------------------------------------------
# Hive (lazy adapters cargados por reflection)
# ---------------------------------------------------------------------
-keep class **$HiveFieldAdapter { *; }
-keep class hive_flutter.** { *; }

# ---------------------------------------------------------------------
# crypto / cookies (java estandar)
# ---------------------------------------------------------------------
-keep class javax.crypto.** { *; }
-keep class java.security.** { *; }

# ---------------------------------------------------------------------
# Atributos clave para reflection y stacktraces utiles
# ---------------------------------------------------------------------
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-keepattributes SourceFile, LineNumberTable

# Mantener stacktraces legibles (numeros de linea) pero ofuscar
# los nombres de archivo a "SourceFile" generico.
-renamesourcefileattribute SourceFile

# ---------------------------------------------------------------------
# Otros
# ---------------------------------------------------------------------
# Kotlin metadata (necesario para algunos plugins)
-keep class kotlin.Metadata { *; }

# AndroidX Core (por compatibilidad con compileSdk 34)
-keep class androidx.core.** { *; }
-dontwarn androidx.core.**

# Suprimir warnings ruidosos de libs maduras.
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**

# ---------------------------------------------------------------------
# Play Core split install — solo se usa si la app tuviera deferred
# components, que no es el caso. R8 ve las referencias en
# `io.flutter.embedding.engine.deferredcomponents` y se queja porque
# las clases `com.google.android.play.core.*` no estan en el classpath.
# Como no usamos esa funcionalidad, le decimos a R8 que ignore esas
# referencias.
# ---------------------------------------------------------------------
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }
