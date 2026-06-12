package com.psk.hearing_aid_app

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Canal de plataforma para guardar archivos en la carpeta Descargas
 * pública del dispositivo, sin pasar por el share sheet del sistema.
 *
 * Resuelve el caso de uso: el técnico genera el `.oirpro.json` y quiere
 * dejarlo guardado en `Download/` del celular para enviarlo después por
 * el medio que prefiera (WhatsApp, Drive, USB), sin depender de
 * `share_plus` (que actualmente está roto por reglas ProGuard
 * incompletas en builds release).
 *
 * Estrategia por versión de Android:
 * - API 29+ (Android 10 / Q): usa `MediaStore.Downloads` con
 *   `ContentValues`. No requiere permisos en runtime ni en manifest.
 * - API ≤28 (Android 9 y anteriores): escribe directo a
 *   `Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)`.
 *   Requiere `WRITE_EXTERNAL_STORAGE` con `maxSdkVersion="28"` en
 *   manifest. Asumimos que el permiso ya fue concedido por el usuario.
 *
 * Devuelve a Flutter una `String` con la ruta absoluta o el URI escrito.
 * Si el método nativo lanza, propaga el error al canal con `result.error`.
 */
class LocalDownloadsChannel(
    private val flutterEngine: FlutterEngine,
    private val context: Context,
) {
    companion object {
        private const val TAG = "LocalDownloadsCh"
        private const val CHANNEL_NAME = "com.psk.hearing_aid/local_downloads"
        private const val MIME_JSON = "application/json"
    }

    private var channel: MethodChannel? = null

    fun register() {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveJsonToDownloads" -> handleSaveJson(call, result)
                else -> result.notImplemented()
            }
        }
        Log.i(TAG, "Channel '$CHANNEL_NAME' registered")
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun handleSaveJson(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val filename = call.argument<String>("filename")
        val content = call.argument<String>("content")
        if (filename.isNullOrBlank() || content == null) {
            result.error(
                "INVALID_ARGS",
                "filename y content son requeridos",
                null,
            )
            return
        }

        try {
            val savedPath = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveViaMediaStore(filename, content)
            } else {
                saveDirectToDownloads(filename, content)
            }
            Log.i(TAG, "Bundle guardado: $savedPath")
            result.success(savedPath)
        } catch (e: Exception) {
            Log.e(TAG, "Error guardando bundle: ${e.message}", e)
            result.error("SAVE_FAILED", e.message ?: "Error desconocido", null)
        }
    }

    /**
     * Android 10+: escribe usando MediaStore.Downloads. No requiere
     * permisos. Si ya existe un archivo con el mismo nombre, MediaStore
     * agrega sufijo numérico automáticamente.
     */
    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    private fun saveViaMediaStore(filename: String, content: String): String {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, filename)
            put(MediaStore.Downloads.MIME_TYPE, MIME_JSON)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val uri = resolver.insert(collection, values)
            ?: throw java.io.IOException("MediaStore.insert devolvió null")

        try {
            resolver.openOutputStream(uri)?.use { stream ->
                stream.write(content.toByteArray(Charsets.UTF_8))
            } ?: throw java.io.IOException("openOutputStream devolvió null")

            // Marcar como ya no pendiente para que el archivo sea
            // visible en la app Files / Mis archivos del usuario.
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Descargas/$filename"
        } catch (e: Exception) {
            // Si falló a mitad de camino, borrar el row pendiente.
            resolver.delete(uri, null, null)
            throw e
        }
    }

    /**
     * Android 9 y anteriores: escribe directo al directorio público
     * Downloads. Requiere `WRITE_EXTERNAL_STORAGE` con
     * `maxSdkVersion="28"` ya solicitado al usuario.
     */
    @Suppress("DEPRECATION")
    private fun saveDirectToDownloads(filename: String, content: String): String {
        val downloads = Environment
            .getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!downloads.exists() && !downloads.mkdirs()) {
            throw java.io.IOException("No se pudo crear ${downloads.absolutePath}")
        }
        val target = File(downloads, filename)
        target.writeText(content, Charsets.UTF_8)
        return target.absolutePath
    }
}
