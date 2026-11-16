package dev.akash.skystream.sniffer

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * 捕获层实现：原生 WebView + document-start 全帧脚本 + 网络请求记录。
 *
 * 关键能力（D2 归因的解法）：
 * - WebViewCompat.addDocumentStartJavaScript(..., setOf("*"))：脚本在主帧与
 *   所有子帧（含跨域 iframe）在任何页内脚本之前运行；必须在 loadUrl 之前注册。
 * - shouldInterceptRequest：主帧与子帧的请求都能看到（ServiceWorker 流量除外，
 *   由页内 performance 快照补）。
 * - 页内脚本：XHR/fetch 记录、video 监听、Blob/MSE 推断。
 *
 * 注意：shouldInterceptRequest 与 JavascriptInterface 回调都不在主线程，
 * 可变状态一律经 mainHandler 串行化或加锁。
 */
class SnifferWebView(
    private val context: Context,
    private val pageScriptCode: String,
) : Sniffer {

    override val id: String = "sniffer-webview"

    private val _state = MutableStateFlow(SniffState.IDLE)
    override val state: StateFlow<SniffState> = _state.asStateFlow()

    private val _events = MutableSharedFlow<SniffEvent>(extraBufferCapacity = 256)
    override val events: Flow<SniffEvent> = _events.asSharedFlow()

    private val _candidates =
        MutableStateFlow<List<DownloadCandidate>>(emptyList())
    override val candidates: StateFlow<List<DownloadCandidate>> =
        _candidates.asStateFlow()

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val dataLock = Any()

    private val recorder = RequestRecorder()
    private val eventBuffer = ArrayDeque<SniffEvent>()
    private val frames = LinkedHashMap<String, FrameSnapshot>()
    private val pageScriptReports =
        mutableListOf<AdapterPipeline.PageScriptReport>()
    private val mediaObservations = mutableListOf<MediaSnapshot>()
    private val blobEvents = mutableListOf<AdapterPipeline.BlobEvent>()
    private val resourceUrls = mutableListOf<String>()
    private var mseActive = false
    private var pageUrl: String = ""
    private var config: SniffConfig = SniffConfig()
    private var pipeline: AdapterPipeline = AdapterPipeline(config)
    private val installedScripts = LinkedHashMap<String, InjectScript>()
    private val documentStartHandlers =
        LinkedHashMap<String, ScriptHandler>()
    private var documentStartSupported: Boolean = false

    private var webView: WebView? = null

    /** 供宿主 Activity/Fragment 挂到界面上的原生 WebView（可为空头跑）。 */
    fun getWebView(): WebView? = webView

    fun loadUrl(url: String) {
        pageUrl = url
        webView?.loadUrl(url)
    }

    /** 清掉上一页的全部记录与候选（导航时用）：不动 state、不动 WebView。 */
    fun clearSession() {
        synchronized(dataLock) {
            recorder.clear()
            eventBuffer.clear()
            frames.clear()
            pageScriptReports.clear()
            mediaObservations.clear()
            blobEvents.clear()
            resourceUrls.clear()
            mseActive = false
            _candidates.value = emptyList()
        }
    }

    /** 换一套生效的路（回滚开关变了时调）：换 config 并重建管线。 */
    fun reconfigure(config: SniffConfig) {
        synchronized(dataLock) {
            this.config = config
            pipeline = AdapterPipeline(config)
        }
    }

    override suspend fun start(config: SniffConfig) {
        if (_state.value == SniffState.RUNNING) {
            throw SniffException.StartFailed("已经在运行，先 stop 再 start")
        }
        if (config.maxCandidates <= 0) {
            throw SniffException.ConfigInvalid("maxCandidates 必须大于 0")
        }
        if (config.timeoutMs <= 0) {
            throw SniffException.ConfigInvalid("timeoutMs 必须大于 0")
        }
        this.config = config
        this.pipeline = AdapterPipeline(config)
        _state.value = SniffState.STARTING
        withContext(Dispatchers.Main) {
            val wv = WebView(context)
            webView = wv
            val settings: WebSettings = wv.settings
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.mediaPlaybackRequiresUserGesture = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS
            settings.setSupportMultipleWindows(false)
            if (config.userAgent.isNotEmpty()) {
                settings.userAgentString = config.userAgent
            }
            wv.webChromeClient = WebChromeClient()
            wv.webViewClient = CaptureWebViewClient()
            wv.addJavascriptInterface(JsBridge(), "Android")
            documentStartSupported = WebViewFeature.isFeatureSupported(
                WebViewFeature.DOCUMENT_START_SCRIPT,
            )
            if (documentStartSupported && config.enablePageScript) {
                try {
                    val handler = WebViewCompat.addDocumentStartJavaScript(
                        wv, pageScriptCode, setOf("*"),
                    )
                    documentStartHandlers["__page_script__"] = handler
                } catch (e: Exception) {
                    Log.w(TAG, "document-start 注册失败，退化为 onPageStarted 补注", e)
                    documentStartSupported = false
                }
            }
            // start 之前 installScript 存下的脚本，在这里补注册。
            if (documentStartSupported) {
                val pending = synchronized(dataLock) {
                    installedScripts.values.filter {
                        it.runAt == RunAt.DOCUMENT_START
                    }
                }
                for (script in pending) {
                    try {
                        val handler = WebViewCompat.addDocumentStartJavaScript(
                            wv, script.code, setOf("*"),
                        )
                        synchronized(dataLock) {
                            documentStartHandlers[script.id] = handler
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "补注册脚本失败：${script.id}", e)
                    }
                }
            }
            _state.value = SniffState.RUNNING
        }
    }

    override suspend fun stop() {
        if (_state.value == SniffState.IDLE) {
            throw SniffException.NotRunning("尚未 start")
        }
        withContext(Dispatchers.Main) {
            webView?.stopLoading()
        }
        _state.value = SniffState.STOPPED
    }

    /** 彻底销毁 WebView 与协程（宿主 onDestroy 时调）。 */
    fun destroy() {
        scope.cancel()
        mainHandler.post {
            webView?.destroy()
            webView = null
        }
    }

    override fun installScript(
        script: InjectScript,
        target: FrameTarget,
    ): ScriptHandle {
        synchronized(dataLock) {
            installedScripts[script.id] = script
        }
        val wv = webView
        // MAIN_FRAME_ONLY 不注册 document-start：document-start 只能全帧注册，
        // 主帧脚本靠 injectNow / onPageStarted 的 evaluateJavascript 下发。
        if (script.runAt == RunAt.DOCUMENT_START && wv != null &&
            target == FrameTarget.ALL_FRAMES && documentStartSupported
        ) {
            try {
                val handler = WebViewCompat.addDocumentStartJavaScript(
                    wv, script.code, setOf("*"),
                )
                synchronized(dataLock) {
                    documentStartHandlers[script.id] = handler
                }
            } catch (e: Exception) {
                throw SniffException.StartFailed("document-start 注册失败：${e.message}")
            }
        }
        return ScriptHandle(script.id)
    }

    override fun uninstallScript(handle: ScriptHandle) {
        synchronized(dataLock) {
            installedScripts.remove(handle.id)
            documentStartHandlers.remove(handle.id)?.remove()
        }
    }

    override suspend fun injectNow(frameId: String, script: InjectScript) {
        val wv = webView ?: throw SniffException.FrameUnavailable("WebView 未创建")
        // evaluateJavascript 只进主帧；子帧靠 document-start 脚本覆盖。
        withContext(Dispatchers.Main) {
            wv.evaluateJavascript(script.code, null)
        }
    }

    override fun onFrameAttached(frame: FrameSnapshot) {
        synchronized(dataLock) { frames[frame.frameId] = frame }
        emit(SniffEvent.FrameAttached(frame))
    }

    override fun onFrameCommitted(frame: FrameSnapshot) {
        synchronized(dataLock) { frames[frame.frameId] = frame }
    }

    override fun onFrameDetached(frameId: String) {
        synchronized(dataLock) { frames.remove(frameId) }
        emit(SniffEvent.FrameDetached(frameId))
    }

    override fun interceptRequest(request: InterceptedRequest): InterceptDecision {
        recorder.record(request)
        emit(SniffEvent.RequestObserved(request))
        return InterceptDecision.ALLOW
    }

    override fun onResponseReceived(response: ResponseSnapshot) {
        emit(SniffEvent.ResponseObserved(response))
        val kind = RequestRecorder.classify(response.url)
        if (kind == RequestRecorder.UrlKind.PLAYLIST ||
            kind == RequestRecorder.UrlKind.MEDIA
        ) {
            onCandidateObserved(
                DownloadCandidate(
                    url = response.url,
                    headers = response.headers,
                    mime = response.mimeType,
                    confidence = CandidateNormalizer.baseScore(CandidateSource.NETWORK),
                    source = CandidateSource.NETWORK,
                ),
            )
        }
    }

    override fun onMediaObserved(media: MediaSnapshot) {
        synchronized(dataLock) {
            mediaObservations.add(media)
            if (mediaObservations.size > 200) mediaObservations.removeAt(0)
        }
        emit(SniffEvent.MediaFound(media))
        runPipeline()
    }

    override fun onCandidateObserved(candidate: DownloadCandidate) {
        val normalized = CandidateNormalizer.normalize(candidate) ?: return
        val prev = _candidates.value
        if (prev.any { it.id == normalized.id }) return
        val merged = CandidateNormalizer.dedupe(prev + normalized)
            .take(config.maxCandidates)
        _candidates.value = merged
        emit(SniffEvent.CandidateFound(normalized))
    }

    override suspend fun drain(timeoutMs: Long): List<SniffEvent> {
        synchronized(dataLock) {
            return eventBuffer.toList()
        }
    }

    override fun snapshot(): SnifferSnapshot {
        synchronized(dataLock) {
            return SnifferSnapshot(
                state = _state.value,
                candidateCount = _candidates.value.size,
                eventCount = eventBuffer.size,
                frames = frames.values.toList(),
            )
        }
    }

    override suspend fun reset() {
        if (_state.value == SniffState.IDLE) {
            throw SniffException.NotRunning("尚未 start")
        }
        recorder.clear()
        synchronized(dataLock) {
            eventBuffer.clear()
            frames.clear()
            pageScriptReports.clear()
            mediaObservations.clear()
            blobEvents.clear()
            resourceUrls.clear()
            mseActive = false
        }
        _candidates.value = emptyList()
        _state.value = SniffState.IDLE
    }

    // ---------- 内部 ----------

    private fun emit(event: SniffEvent) {
        synchronized(dataLock) {
            if (eventBuffer.size >= 1000) eventBuffer.removeFirst()
            eventBuffer.addLast(event)
        }
        _events.tryEmit(event)
    }

    /** 汇总各路记录跑一次管线，刷新候选列表。 */
    private fun runPipeline() {
        if (_state.value != SniffState.RUNNING) return
        val inputs: AdapterPipeline.Inputs
        synchronized(dataLock) {
            inputs = AdapterPipeline.Inputs(
                pageUrl = pageUrl,
                requests = recorder.drain(),
                pageScriptReports = pageScriptReports.toList(),
                media = mediaObservations.toList(),
                blobEvents = blobEvents.toList(),
                mseActive = mseActive,
                resourceUrls = resourceUrls.toList(),
            )
        }
        val found = pipeline.run(inputs)
        if (found.isEmpty()) return
        val prev = _candidates.value
        val merged = CandidateNormalizer.dedupe(prev + found)
            .take(config.maxCandidates)
        if (merged != prev) {
            _candidates.value = merged
            val prevIds = prev.map { it.id }.toSet()
            for (c in merged) {
                if (c.id !in prevIds) emit(SniffEvent.CandidateFound(c))
            }
        }
    }

    /** 向页内要 frame 树与 performance 资源快照（evaluateJavascript，主帧）。 */
    private fun collectFramesAndResources() {
        val wv = webView ?: return
        wv.evaluateJavascript("window.__thFrames ? window.__thFrames() : {}") { json ->
            try {
                val root = JSONObject(json ?: "{}")
                val list = mutableListOf<FrameSnapshot>()
                walkFrameJson(root, "main", 0, list)
                mainHandler.post {
                    for (f in list) {
                        val prev = synchronized(dataLock) { frames[f.frameId] }
                        if (prev == null) {
                            onFrameAttached(f)
                        } else {
                            onFrameCommitted(f)
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
        wv.evaluateJavascript(
            "window.__thResources ? window.__thResources() : []",
        ) { json ->
            try {
                val arr = JSONArray(json ?: "[]")
                val urls = mutableListOf<String>()
                for (i in 0 until arr.length()) {
                    urls.add(arr.optString(i))
                }
                synchronized(dataLock) {
                    resourceUrls.clear()
                    resourceUrls.addAll(urls)
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun walkFrameJson(
        node: JSONObject,
        frameId: String,
        depth: Int,
        out: MutableList<FrameSnapshot>,
    ) {
        val url = node.optString("url", "")
        val children = node.optInt("children", 0)
        out.add(
            FrameSnapshot(
                frameId = frameId,
                url = if (url == "cross-origin") null else url,
                isCrossOrigin = url == "cross-origin",
                depth = depth,
                childCount = children,
            ),
        )
        val arr = node.optJSONArray("frames") ?: return
        for (i in 0 until arr.length()) {
            walkFrameJson(arr.getJSONObject(i), "$frameId/$i", depth + 1, out)
        }
    }

    private inner class CaptureWebViewClient : WebViewClient() {
        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse? {
            val headers = mutableMapOf<String, String>()
            request.requestHeaders?.forEach { (k, v) -> headers[k] = v }
            interceptRequest(
                InterceptedRequest(
                    url = request.url.toString(),
                    method = request.method,
                    headers = headers,
                    isForMainFrame = request.isForMainFrame,
                    hasGesture = request.hasGesture(),
                    isRedirect = request.isRedirect,
                ),
            )
            return null
        }

        override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
            pageUrl = url
            emit(SniffEvent.PageStarted(url))
            // 老版本无 document-start 时退化：主帧补注一次。
            if (!documentStartSupported && config.enablePageScript) {
                view.evaluateJavascript(pageScriptCode, null)
            }
            collectFramesAndResources()
            super.onPageStarted(view, url, favicon)
        }

        override fun onPageFinished(view: WebView, url: String) {
            collectFramesAndResources()
            runPipeline()
            super.onPageFinished(view, url)
        }
    }

    /** 页内脚本回调（JavascriptInterface，回调不在主线程，进来先贴到主线程）。 */
    private inner class JsBridge {
        @JavascriptInterface
        fun onRequest(url: String, type: String, body: String) {
            mainHandler.post {
                synchronized(dataLock) {
                    pageScriptReports.add(
                        AdapterPipeline.PageScriptReport(url, type, body),
                    )
                    if (pageScriptReports.size > 500) {
                        pageScriptReports.removeAt(0)
                    }
                }
                emit(
                    SniffEvent.RequestObserved(
                        InterceptedRequest(url = url, method = type),
                    ),
                )
                runPipeline()
            }
        }

        @JavascriptInterface
        fun onMedia(url: String, tag: String, duration: String, playing: String) {
            mainHandler.post {
                onMediaObserved(
                    MediaSnapshot(
                        url = url,
                        tagName = tag,
                        currentSrc = url,
                        durationMs = duration.toLongOrNull() ?: 0L,
                        isPlaying = playing.toBoolean(),
                    ),
                )
            }
        }

        @JavascriptInterface
        fun onBlob(url: String, kind: String) {
            mainHandler.post {
                synchronized(dataLock) {
                    blobEvents.add(AdapterPipeline.BlobEvent(url, kind))
                    if (blobEvents.size > 200) blobEvents.removeAt(0)
                }
            }
        }

        @JavascriptInterface
        fun onBlobRevoked(url: String) {
            mainHandler.post {
                synchronized(dataLock) {
                    blobEvents.removeAll { it.url == url }
                }
            }
        }

        @JavascriptInterface
        fun onMse(mime: String) {
            mainHandler.post { mseActive = true }
        }

        @JavascriptInterface
        fun onMseAppend(mime: String, size: String) {
            mainHandler.post { mseActive = true }
        }
    }

    companion object {
        private const val TAG = "SnifferWebView"
    }
}
