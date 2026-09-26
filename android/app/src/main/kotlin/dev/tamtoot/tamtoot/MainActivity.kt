package dev.tamtoot.tamtoot

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** SAF export adapter. No broad storage permission is requested. */
class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingText: String? = null
    private val createDocumentRequest = 4810

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.tamtoot/documents")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveText") {
                    result.notImplemented()
                } else if (pending != null) {
                    result.error("BUSY", "Another document export is in progress", null)
                } else {
                    val text = call.argument<String>("text")
                    val name = call.argument<String>("name")
                    if (text == null || name == null) {
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
            }
    }

    @Deprecated("Activity result bridge for Flutter document channel")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != createDocumentRequest) return
        val result = pending ?: return
        val text = pendingText ?: ""
        pending = null
        pendingText = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
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
