package dev.tamtoot.tamtoot

import android.content.Context
import android.view.View
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebChromeClient
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class SitePreviewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView = SitePreview(context, args)
}

private class SitePreview(context: Context, args: Any?) : PlatformView {
    private val webView = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        webViewClient = WebViewClient()
        webChromeClient = WebChromeClient()
        val url = (args as? Map<*, *>)?.get("url") as? String
        if (url != null && (url.startsWith("http://") || url.startsWith("https://"))) loadUrl(url)
    }
    override fun getView(): View = webView
    override fun dispose() { webView.stopLoading(); webView.destroy() }
}
