package work.shuyo.app

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingExactAlarmResult: MethodChannel.Result? = null
    private var pendingAlarmRingtoneResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "work.shuyo.app/build_info"
        ).setMethodCallHandler { call, result ->
            if (call.method == "getBuildInfo") {
                result.success(
                    mapOf(
                        "branch" to BuildConfig.GIT_BRANCH,
                        "commitHash" to BuildConfig.GIT_COMMIT
                    )
                )
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "work.shuyo.app/image_saver"
        ).setMethodCallHandler { call, result ->
            if (call.method == "saveImage") {
                saveImage(
                    call.argument("bytes"),
                    call.argument("filename"),
                    call.argument("mimeType"),
                    result
                )
            } else {
                result.notImplemented()
            }
        }
        getPreferences(MODE_PRIVATE).edit().remove("emoji_recents").apply()
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "work.shuyo.app/early_class_alarms"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(EarlyClassAlarmScheduler.isAvailable(this))
                "requestAuthorization" -> requestExactAlarmAuthorization(result)
                "getRingtone" -> result.success(EarlyClassAlarmScheduler.getRingtone(this))
                "pickRingtone" -> pickAlarmRingtone(result)
                "sync" -> {
                    val alarms = call.argument<List<Map<String, Any?>>>("alarms") ?: emptyList()
                    result.success(EarlyClassAlarmScheduler.sync(this, alarms))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        pendingExactAlarmResult?.let { result ->
            val manager = getSystemService(android.app.AlarmManager::class.java)
            val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                manager.canScheduleExactAlarms()
            pendingExactAlarmResult = null
            result.success(allowed)
        }
        EarlyClassAlarmService.activeAlarmIntent(this)?.let(::startActivity)
    }

    private fun requestExactAlarmAuthorization(result: MethodChannel.Result) {
        val manager = getSystemService(android.app.AlarmManager::class.java)
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            manager.canScheduleExactAlarms()
        if (allowed) {
            result.success(true)
            return
        }
        if (pendingExactAlarmResult != null) {
            result.error("busy", "Exact alarm permission request is already open", null)
            return
        }

        pendingExactAlarmResult = result
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                    data = Uri.parse("package:$packageName")
                },
            )
        } catch (error: Exception) {
            pendingExactAlarmResult = null
            result.error("permission_unavailable", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK_ALARM_RINGTONE) {
            val result = pendingAlarmRingtoneResult ?: return
            pendingAlarmRingtoneResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result.success(null)
                return
            }
            val uri = data.data!!
            try {
                val takeFlags = data.flags and
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (takeFlags != 0) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                }
            } catch (_: SecurityException) {
                // Some document providers do not offer persistable permissions.
                // The selected URI can still be used for the current installation.
            }
            val name = displayName(uri, "自定义铃声")
            getSharedPreferences(EarlyClassAlarmScheduler.PREFS, MODE_PRIVATE)
                .edit()
                .putString(EarlyClassAlarmScheduler.RINGTONE_URI_KEY, uri.toString())
                .putString(EarlyClassAlarmScheduler.RINGTONE_NAME_KEY, name)
                .apply()
            result.success(mapOf("name" to name))
            return
        }
    }

    private fun displayName(uri: Uri, fallback: String = "image.jpg"): String {
        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(uri, null, null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    return cursor.getString(index)
                }
            }
        } finally {
            cursor?.close()
        }
        return fallback
    }

    private fun saveImage(
        bytes: ByteArray?,
        filename: String?,
        mimeType: String?,
        result: MethodChannel.Result
    ) {
        if (bytes == null || bytes.isEmpty()) {
            result.error("empty_image", "Image bytes are empty", null)
            return
        }
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, filename ?: "shuyo_image.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, mimeType ?: "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/ShuYo"
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val resolver = contentResolver
        var uri: Uri? = null
        try {
            uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            if (uri == null) {
                result.error("save_failed", "Cannot create image entry", null)
                return
            }
            resolver.openOutputStream(uri)?.use { output ->
                output.write(bytes)
            } ?: throw IllegalStateException("Cannot open image output stream")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            result.success(uri.toString())
        } catch (error: Exception) {
            if (uri != null) {
                resolver.delete(uri, null, null)
            }
            result.error("save_failed", error.message, null)
        }
    }

    private fun pickAlarmRingtone(result: MethodChannel.Result) {
        if (pendingAlarmRingtoneResult != null) {
            result.error("busy", "Ringtone picker is already open", null)
            return
        }
        pendingAlarmRingtoneResult = result
        try {
            startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "audio/*"
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                    )
                },
                REQUEST_PICK_ALARM_RINGTONE,
            )
        } catch (error: Exception) {
            pendingAlarmRingtoneResult = null
            result.error("picker_unavailable", error.message, null)
        }
    }

    companion object {
        private const val REQUEST_PICK_ALARM_RINGTONE = 9102
    }
}
