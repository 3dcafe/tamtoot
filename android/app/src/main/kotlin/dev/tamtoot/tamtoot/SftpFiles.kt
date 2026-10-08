package dev.tamtoot.tamtoot

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Binary SAF bridge, bounded and scoped to a user-picked document. */
class SftpFiles(private val activity: Activity, messenger: BinaryMessenger) {
    private var pending: MethodChannel.Result? = null
    private var saving: ByteArray? = null
    private val pickRequest = 4820
    private val saveRequest = 4821
    init {
        MethodChannel(messenger, "dev.tamtoot/sftp_files").setMethodCallHandler { call, result ->
            if (pending != null) { result.error("BUSY", "File picker is already open", null); return@setMethodCallHandler }
            try {
                when(call.method) {
                    "pick" -> {
                        pending = result
                        activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }, pickRequest)
                    }
                    "save" -> {
                        val bytes = call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("Missing bytes")
                        require(bytes.size <= 32 * 1024 * 1024) { "File exceeds 32 MiB" }
                        saving = bytes; pending = result
                        val name = (call.argument<String>("name") ?: "download").map { if (it == '/' || it == '\\' || it.code < 32) '_' else it }.joinToString("")
                        activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE); type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, name); addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        }, saveRequest)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { pending = null; saving = null; result.error("FILE", "Unable to open document picker", null) }
        }
    }
    fun onResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != pickRequest && request != saveRequest) return false
        val reply = pending ?: return true
        val bytes = saving; pending = null; saving = null
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) { reply.success(if(request == saveRequest) false else null); return true }
        Thread {
            try {
                if (request == saveRequest) {
                    val output = activity.contentResolver.openOutputStream(uri, "wt") ?: throw IllegalStateException()
                    output.use { it.write(bytes ?: throw IllegalStateException()) }
                    activity.runOnUiThread { reply.success(true) }
                } else {
                    var name = "upload"
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst()) name = it.getString(0) ?: name
                    }
                    val output = java.io.ByteArrayOutputStream()
                    val input = activity.contentResolver.openInputStream(uri) ?: throw IllegalStateException()
                    input.use {
                        val buffer = ByteArray(32768)
                        while(true) {
                            val count = it.read(buffer); if(count < 0) break
                            require(output.size() + count <= 32 * 1024 * 1024) { "File exceeds 32 MiB" }
                            output.write(buffer, 0, count)
                        }
                    }
                    val value = mapOf("name" to name, "bytes" to output.toByteArray())
                    activity.runOnUiThread { reply.success(value) }
                }
            } catch (_: Exception) { activity.runOnUiThread { reply.error("FILE", "Document operation failed or exceeded 32 MiB", null) } }
        }.start()
        return true
    }
}
