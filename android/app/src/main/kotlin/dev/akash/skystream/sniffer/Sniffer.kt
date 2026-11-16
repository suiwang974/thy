package dev.akash.skystream.sniffer

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/**
 * 捕获层接口（D3 契约）。实现见 SnifferWebView。
 * state/events/candidates 由原生侧 Flow 驱动，Dart 侧经 MethodChannel/EventChannel 桥接。
 */
interface Sniffer {
    val id: String
    val state: StateFlow<SniffState>
    val events: Flow<SniffEvent>
    val candidates: StateFlow<List<DownloadCandidate>>

    @Throws(SniffException.ConfigInvalid::class, SniffException.StartFailed::class)
    suspend fun start(config: SniffConfig)

    @Throws(SniffException.NotRunning::class)
    suspend fun stop()

    @Throws(SniffException.StartFailed::class)
    fun installScript(
        script: InjectScript,
        target: FrameTarget = FrameTarget.ALL_FRAMES,
    ): ScriptHandle

    fun uninstallScript(handle: ScriptHandle)

    @Throws(SniffException.FrameUnavailable::class, SniffException.InjectionRejected::class)
    suspend fun injectNow(frameId: String, script: InjectScript)

    fun onFrameAttached(frame: FrameSnapshot)
    fun onFrameCommitted(frame: FrameSnapshot)
    fun onFrameDetached(frameId: String)
    fun interceptRequest(request: InterceptedRequest): InterceptDecision
    fun onResponseReceived(response: ResponseSnapshot)
    fun onMediaObserved(media: MediaSnapshot)
    fun onCandidateObserved(candidate: DownloadCandidate)
    suspend fun drain(timeoutMs: Long = DEFAULT_DRAIN_TIMEOUT_MS): List<SniffEvent>

    fun snapshot(): SnifferSnapshot

    @Throws(SniffException.NotRunning::class)
    suspend fun reset()

    companion object {
        const val DEFAULT_DRAIN_TIMEOUT_MS: Long = 1_000L
    }
}

/** 网络记录的裁决：只做记录，不改请求。 */
enum class InterceptDecision { ALLOW, BLOCK }
