package dev.akash.skystream.extractor

import dev.akash.skystream.sniffer.DownloadCandidate
import dev.akash.skystream.sniffer.EncryptionInfo
import dev.akash.skystream.sniffer.Variant

/**
 * Extractor 支撑模型（D3 契约）。
 * 偏差记录：D3 原文把 DownloadCandidate 放在 dev.akash.skystream.model，
 * 这里合并到 sniffer 包（已实现的唯一 DownloadCandidate），避免同名重复类；
 * D3 的 JsonElement（kotlinx.serialization）改成 Android 内置 org.json.JSONObject，
 * 不新增依赖。
 */

data class ExtractorProfile(
    val id: String,
    val name: String,
    val version: String = "1.0",
)

data class SourceProbe(
    val url: String,
    val host: String = "",
    val htmlSnippet: String = "",
)

data class ExtractTarget(
    val url: String,
    val pageUrl: String = "",
    val headers: Map<String, String> = emptyMap(),
)

data class ExtractContext(
    val pageUrl: String = "",
    val headers: Map<String, String> = emptyMap(),
    val cookies: List<String> = emptyList(),
    val referer: String? = null,
    val timeoutMs: Long = 15000L,
)

data class ExtractResult(
    val candidates: List<DownloadCandidate>,
    val playlists: List<PlaylistGraph> = emptyList(),
)

data class PlaylistPayload(
    val text: String,
    val url: String,
    val contentType: String? = null,
)

data class PlaylistGraph(
    val url: String,
    val isMaster: Boolean,
    val variants: List<Variant> = emptyList(),
    val media: MediaPlaylist? = null,
)

enum class VariantPolicy { HIGHEST_BANDWIDTH, LOWEST_BANDWIDTH, PREFER_720P }

data class MediaPlaylist(
    val url: String,
    val segments: List<Segment>,
    val initSegment: InitSegment? = null,
    val isLive: Boolean = false,
    val mediaSequence: Long = 0L,
    val totalDurationMs: Long = 0L,
)

data class Segment(
    val url: String,
    val durationMs: Long,
    val sequence: Long,
    val key: EncryptionInfo? = null,
    val byteRangeLength: Long? = null,
    val byteRangeOffset: Long? = null,
)

data class InitSegment(
    val url: String,
    val byteRangeLength: Long? = null,
    val byteRangeOffset: Long? = null,
)

data class SegmentRequest(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val byteRangeLength: Long? = null,
    val byteRangeOffset: Long? = null,
)

data class KeyRef(val uri: String, val method: String = "AES-128")

data class KeyMaterial(val bytes: ByteArray, val method: String = "AES-128") {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is KeyMaterial) return false
        return method == other.method && bytes.contentEquals(other.bytes)
    }

    override fun hashCode(): Int {
        var result = method.hashCode()
        result = 31 * result + bytes.contentHashCode()
        return result
    }
}

enum class EncryptionMethod { NONE, AES_128, SAMPLE_AES, UNKNOWN }

enum class UrlKind { PLAYLIST, MEDIA, PAGE, OTHER }

data class ExtractedUrl(
    val url: String,
    val kind: UrlKind,
    val mime: String? = null,
)

data class UrlSpec(
    val includePatterns: List<String> = emptyList(),
    val excludePatterns: List<String> = emptyList(),
)

data class ExtractorInput(
    val text: String = "",
    val baseUrl: String = "",
    val headers: Map<String, String> = emptyMap(),
)

sealed class ExtractException(message: String) : Exception(message) {
    class Unsupported(message: String) : ExtractException(message)
    class Cancelled(message: String) : ExtractException(message)
    class NotPlaylist(message: String) : ExtractException(message)
    class ParseFailed(message: String) : ExtractException(message)
    class DrmProtected(message: String) : ExtractException(message)
    class DepthExceeded(message: String) : ExtractException(message)
    class VariantNotFound(message: String) : ExtractException(message)
    class KeyFetchFailed(message: String) : ExtractException(message)
    class DecryptFailed(message: String) : ExtractException(message)
    class RefreshFailed(message: String) : ExtractException(message)
}
