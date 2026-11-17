package dev.akash.skystream.extractor

import dev.akash.skystream.sniffer.DownloadCandidate
import dev.akash.skystream.sniffer.EncryptionInfo
import dev.akash.skystream.sniffer.Variant
import org.json.JSONObject

/**
 * 提取层接口（D3 契约）。实现见 ExtractorImpl。
 * 偏差：D3 的 JsonElement（kotlinx.serialization）改成 Android 内置
 * org.json.JSONObject；DownloadCandidate/Variant 在 sniffer 包（唯一一份）。
 */
interface Extractor {
    val id: String
    val profile: ExtractorProfile

    fun supports(probe: SourceProbe): Boolean

    @Throws(ExtractException.Unsupported::class, ExtractException.Cancelled::class)
    suspend fun extract(target: ExtractTarget, ctx: ExtractContext): ExtractResult

    @Throws(
        ExtractException.NotPlaylist::class,
        ExtractException.ParseFailed::class,
        ExtractException.DrmProtected::class,
    )
    suspend fun parsePlaylist(payload: PlaylistPayload, ctx: ExtractContext): PlaylistGraph

    @Throws(
        ExtractException.ParseFailed::class,
        ExtractException.DepthExceeded::class,
        ExtractException.Cancelled::class,
    )
    suspend fun expandMaster(
        master: PlaylistGraph,
        ctx: ExtractContext,
        depth: Int = 0,
    ): List<Variant>

    @Throws(ExtractException.VariantNotFound::class)
    fun selectVariant(variants: List<Variant>, policy: VariantPolicy): Variant

    fun mediaOf(graph: PlaylistGraph, variant: Variant?): MediaPlaylist
    fun isLive(playlist: MediaPlaylist): Boolean
    fun initSegmentOf(playlist: MediaPlaylist): InitSegment?
    fun parseSegments(playlist: MediaPlaylist): List<Segment>
    fun resolveUri(baseUri: String, reference: String): String
    fun absolutize(playlist: MediaPlaylist): MediaPlaylist
    fun planRequests(segments: List<Segment>, ctx: ExtractContext): List<SegmentRequest>

    fun encryptionOf(playlist: MediaPlaylist): List<EncryptionInfo>
    @Throws(ExtractException.KeyFetchFailed::class, ExtractException.Cancelled::class)
    suspend fun fetchKey(ref: KeyRef, ctx: ExtractContext): KeyMaterial

    fun deriveIv(sequence: Long, explicitIv: ByteArray?, key: KeyMaterial): ByteArray

    @Throws(ExtractException.DecryptFailed::class)
    fun decrypt(
        data: ByteArray,
        key: KeyMaterial,
        iv: ByteArray,
        method: EncryptionMethod,
    ): ByteArray

    @Throws(
        ExtractException.KeyFetchFailed::class,
        ExtractException.DecryptFailed::class,
        ExtractException.Cancelled::class,
    )
    suspend fun decryptSegment(
        segment: Segment,
        key: KeyMaterial,
        iv: ByteArray,
        ctx: ExtractContext,
    ): ByteArray

    fun extractUrls(input: ExtractorInput, spec: UrlSpec): List<ExtractedUrl>
    fun extractUrls(node: JSONObject, spec: UrlSpec): List<ExtractedUrl>
    fun extractUrls(attributes: Map<String, String>, spec: UrlSpec): List<ExtractedUrl>
    fun normalize(url: String, baseUri: String? = null): String?
    fun classify(url: String, mime: String?, magic: ByteArray? = null): UrlKind

    fun toCandidate(url: ExtractedUrl, ctx: ExtractContext): DownloadCandidate?
    fun score(candidate: DownloadCandidate, ctx: ExtractContext): Float
    fun dedupe(candidates: List<DownloadCandidate>): List<DownloadCandidate>

    @Throws(ExtractException.RefreshFailed::class, ExtractException.Cancelled::class)
    suspend fun refresh(candidate: DownloadCandidate, ctx: ExtractContext): DownloadCandidate

    fun isExpired(candidate: DownloadCandidate, nowMs: Long = System.currentTimeMillis()): Boolean
    fun close()

    companion object {
        const val MAX_MASTER_DEPTH: Int = 3
        const val DEFAULT_TIMEOUT_MS: Long = 15_000L
    }
}
