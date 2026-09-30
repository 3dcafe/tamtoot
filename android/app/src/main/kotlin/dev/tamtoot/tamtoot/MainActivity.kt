package dev.tamtoot.tamtoot

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** SAF export adapter. No broad storage permission is requested. */
class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingText: String? = null
    private val createDocumentRequest = 4810
    private val openDocumentRequest = 4811

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.tamtoot/documents")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url == null) {
                            result.error("ARGUMENT", "url is required", null)
                        } else {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(true)
                        }
                    }
                    "openText" -> openText(result)
                    "readText" -> withDocument(call.argument<String>("uri"), result) { uri ->
                        val stream = contentResolver.openInputStream(uri)
                            ?: throw IllegalStateException("Provider did not return an input stream")
                        stream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                    }
                    "writeText" -> withDocument(call.argument<String>("uri"), result) { uri ->
                        val text = call.argument<String>("text")
                            ?: throw IllegalArgumentException("text is required")
                        val stream = contentResolver.openOutputStream(uri, "wt")
                            ?: throw IllegalStateException("Provider did not return an output stream")
                        stream.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                        true
                    }
                    "saveText" -> saveText(
                        call.argument<String>("name"),
                        call.argument<String>("text"),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun openText(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "Another document picker is in progress", null)
            return
        }
        pending = result
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "text/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }, openDocumentRequest)
        } catch (error: Exception) {
            pending = null
            result.error("OPEN", error.message, null)
        }
    }

    private fun saveText(name: String?, text: String?, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("BUSY", "Another document picker is in progress", null)
        } else if (text == null || name == null) {
            result.error("ARGUMENT", "name and text are required", null)
        } else {
            pending = result
            pendingText = text
            try {
                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TITLE, name)
                }, createDocumentRequest)
            } catch (error: Exception) {
                pending = null
                pendingText = null
                result.error("EXPORT", error.message, null)
            }
        }
    }

    private fun <T> withDocument(
        rawUri: String?,
        result: MethodChannel.Result,
        action: (Uri) -> T,
    ) {
        if (rawUri == null) {
            result.error("ARGUMENT", "uri is required", null)
            return
        }
        Thread {
            try {
                val value = action(Uri.parse(rawUri))
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread { result.error("DOCUMENT", error.message, null) }
            }
        }.start()
    }

    @Deprecated("Activity result bridge for Flutter document channel")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != createDocumentRequest && requestCode != openDocumentRequest) return
        val result = pending ?: return
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pendingText = null
            result.success(null)
            return
        }
        if (requestCode == openDocumentRequest) {
            val flags = (data?.flags ?: 0) and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            try {
                contentResolver.takePersistableUriPermission(uri, flags)
            } catch (_: SecurityException) {
                // Some providers grant access for the current app session only.
            }
            Thread {
                try {
                    val stream = contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("Provider did not return an input stream")
                    val text = stream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                    var name = uri.lastPathSegment ?: "document.txt"
                    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                    }
                    runOnUiThread {
                        result.success(mapOf("uri" to uri.toString(), "name" to name, "text" to text))
                    }
                } catch (error: Exception) {
                    runOnUiThread { result.error("READ", error.message, null) }
                }
            }.start()
            return
        }
        val text = pendingText ?: ""
        pendingText = null
        // File writes stay off the Android UI thread.
        Thread {
            try {
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("Provider did not return an output stream")
                stream.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                runOnUiThread { result.success(uri.toString()) }
            } catch (error: Exception) {
                runOnUiThread { result.error("WRITE", error.message, null) }
            }
        }.start()
    }
}
