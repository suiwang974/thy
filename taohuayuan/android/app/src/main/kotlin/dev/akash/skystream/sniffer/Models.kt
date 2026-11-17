package dev.akash.skystream.sniffer

/// 六路来源：网络层记录、ServiceWorker、页内脚本、video 监听、规则拼接、Blob/MSE 推断、直链。
enum class CandidateSource {
    NETWORK, SERVICE_WORKER, PAGE_SCRIPT, VIDEO_LISTENER, RULE, BLOB_MSE, DIRECT
}

data class Variant(
    val url: String = "",
    val resolution: String = "",
    val bandwidth: Long = 0L,
    val codecs: String = "",
    val initSegment: String? = null,
    val encryption: EncryptionInfo? = null,
    val durationMs: Long = 0L,
    val segmentCount: Int = 0,
)

data class EncryptionInfo(
    val method: String = "NONE",
    val uri: String = "",
    val iv: ByteArray? = null,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is EncryptionInfo) return false
        return method == other.method && uri == other.uri &&
            (iv == null && other.iv == null ||
                iv != null && other.iv != null && iv.contentEquals(other.iv))
    }

    override fun hashCode(): Int {
        var result = method.hashCode()
        result = 31 * result + uri.hashCode()
        result = 31 * result + (iv?.contentHashCode() ?: 0)
        return result
    }
}

/// 下载候选：捕获层产出、传输层消费。与 Dart 侧 DownloadCandidate 字段一致。
data class DownloadCandidate(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val referer: String? = null,
    val cookies: List<String> = emptyList(),
    val mime: String? = null,
    val variant: Variant? = null,
    val confidence: Float = 0.5f,
    val source: CandidateSource = CandidateSource.NETWORK,
    val contentHash: String? = null,
    val expiresAt: Long? = null,
) {
    /** 一级去重键：规范化 URL（去 fragment、小写）。 */
    val id: String get() = url.substringBefore('#').lowercase()
}

enum class SniffState { IDLE, STARTING, RUNNING, STOPPED, FAILED }

sealed class SniffEvent {
    abstract val timestampMs: Long

    data class PageStarted(
        val url: String,
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : SniffEvent()

    data class RequestObserved(
        val request: InterceptedRequest,
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : SniffEvent()

    data class ResponseObserved(
        val response: ResponseSnapshot,
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : SniffEvent()

    data class MediaFound(
        val media: MediaSnapshot,
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : SniffEvent()

    data class CandidateFound(
        val candidate: DownloadCandidate,
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : SniffEvent()

    data class FrameAttached(
        val frame: FrameSnapshot,
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : SniffEvent()

    data class FrameDetached(
        val frameId: String,
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : SniffEvent()

    data class Error(
        val message: String,
        override val timestampMs: Long = System.currentTimeMillis(),
    ) : SniffEvent()
}

data class SniffConfig(
    val userAgent: String = "",
    val enablePageScript: Boolean = true,
    val adapterOrder: List<CandidateSource> = listOf(
        CandidateSource.NETWORK,
        CandidateSource.SERVICE_WORKER,
        CandidateSource.PAGE_SCRIPT,
        CandidateSource.VIDEO_LISTENER,
        CandidateSource.RULE,
        CandidateSource.BLOB_MSE,
    ),
    val timeoutMs: Long = 15000L,
    val maxCandidates: Int = 50,
)

enum class RunAt { DOCUMENT_START, DOCUMENT_END }

data class InjectScript(
    val id: String,
    val code: String,
    val runAt: RunAt = RunAt.DOCUMENT_START,
)

enum class FrameTarget { ALL_FRAMES, MAIN_FRAME_ONLY }

data class ScriptHandle(val id: String)

data class FrameSnapshot(
    val frameId: String,
    val parentId: String? = null,
    val url: String? = null,
    val isCrossOrigin: Boolean = false,
    val depth: Int = 0,
    val childCount: Int = 0,
)

data class InterceptedRequest(
    val url: String,
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val isForMainFrame: Boolean = false,
    val frameId: String? = null,
    val hasGesture: Boolean = false,
    val isRedirect: Boolean = false,
)

data class ResponseSnapshot(
    val url: String,
    val statusCode: Int = 200,
    val mimeType: String? = null,
    val headers: Map<String, String> = emptyMap(),
    val frameId: String? = null,
)

data class MediaSnapshot(
    val url: String,
    val tagName: String = "video",
    val currentSrc: String? = null,
    val durationMs: Long = 0L,
    val isPlaying: Boolean = false,
)

sealed class SniffException(message: String) : Exception(message) {
    class ConfigInvalid(message: String) : SniffException(message)
    class StartFailed(message: String) : SniffException(message)
    class NotRunning(message: String) : SniffException(message)
    class FrameUnavailable(message: String) : SniffException(message)
    class InjectionRejected(message: String) : SniffException(message)
}

data class SnifferSnapshot(
    val state: SniffState,
    val candidateCount: Int,
    val eventCount: Int,
    val frames: List<FrameSnapshot>,
)
