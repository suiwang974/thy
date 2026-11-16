package dev.akash.skystream.extractor

import dev.akash.skystream.sniffer.CandidateNormalizer
import dev.akash.skystream.sniffer.CandidateSource
import dev.akash.skystream.sniffer.DownloadCandidate
import dev.akash.skystream.sniffer.EncryptionInfo
import dev.akash.skystream.sniffer.RequestRecorder
import dev.akash.skystream.sniffer.Variant
import java.net.HttpURLConnection
import java.net.URL
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.json.JSONArray
import org.json.JSONObject

/**
 * 提取层实现（D3 契约 + HlsPlaylistKt）。
 * - 播放列表解析走 HlsPlaylistKt（与 Dart 侧同一套规则）。
 * - AES-128 解密走 Android 内置 JCE（AES/CBC/PKCS5Padding），不新增依赖。
 * - 密钥/分片拉取走 HttpURLConnection（带 ctx 的 headers/referer/cookies）。
 * - mediaOf 是纯访问器：parsePlaylist 只解析给定的文本，不主动拉变体列表；
 *   要拿某变体的 media，先对变体 URL 调 parsePlaylist（或 expandMaster）。
 */
class ExtractorImpl : Extractor {

    override val id: String = "extractor-default"
    override val profile: ExtractorProfile =
        ExtractorProfile(id = id, name = "DefaultExtractor", version = "1.0")

    private var closed = false

    override fun supports(probe: SourceProbe): Boolean {
        val url = probe.url.lowercase()
        return url.startsWith("http://") || url.startsWith("https://")
    }

    override suspend fun extract(
        target: ExtractTarget,
        ctx: ExtractContext,
    ): ExtractResult {
        ensureOpen()
        val kind = classify(target.url, null)
        if (kind != UrlKind.PLAYLIST) {
            return ExtractResult(candidates = emptyList())
        }
        val text = fetchText(target.url, ctx)
        val graph = parsePlaylist(PlaylistPayload(text, target.url), ctx)
        val candidates = graph.variants.mapNotNull { v ->
            toCandidate(
                ExtractedUrl(v.url, UrlKind.PLAYLIST),
                ctx,
            )?.copy(variant = v)
        }.ifEmpty {
            graph.media?.let { media ->
                listOfNotNull(
                    toCandidate(ExtractedUrl(media.url, UrlKind.PLAYLIST), ctx),
                )
            } ?: emptyList()
        }
        return ExtractResult(candidates = candidates, playlists = listOf(graph))
    }

    override suspend fun parsePlaylist(
        payload: PlaylistPayload,
        ctx: ExtractContext,
    ): PlaylistGraph {
        ensureOpen()
        val text = payload.text
        if (!text.contains("#EXTM3U") && !text.contains("#EXT-X-STREAM-INF")) {
            throw ExtractException.NotPlaylist("不是 HLS 播放列表：${payload.url}")
        }
        if (text.contains("skd://") || text.contains("METHOD=SAMPLE-AES")) {
            throw ExtractException.DrmProtected("DRM 保护的播放列表，放弃：${payload.url}")
        }
        if (HlsPlaylistKt.isMaster(text)) {
            val variants = HlsPlaylistKt.parseMaster(text, payload.url)
            if (variants.isEmpty()) {
                throw ExtractException.ParseFailed("master 列表里没有变体：${payload.url}")
            }
            return PlaylistGraph(url = payload.url, isMaster = true, variants = variants)
        }
        val media = HlsPlaylistKt.parseMedia(text, payload.url)
        return PlaylistGraph(url = payload.url, isMaster = false, media = media)
    }

    override suspend fun expandMaster(
        master: PlaylistGraph,
        ctx: ExtractContext,
        depth: Int,
    ): List<Variant> {
        ensureOpen()
        if (depth > MAX_MASTER_DEPTH) {
            throw ExtractException.DepthExceeded("master 递归超过 $MAX_MASTER_DEPTH 层")
        }
        if (!master.isMaster) return master.variants
        val out = mutableListOf<Variant>()
        for (v in master.variants) {
            try {
                val text = fetchText(v.url, ctx)
                val media = HlsPlaylistKt.parseMedia(text, v.url)
                val enc = media.segments.firstNotNullOfOrNull { it.key }
                out.add(
                    v.copy(
                        segmentCount = media.segments.size,
                        durationMs = media.totalDurationMs,
                        encryption = enc,
                    ),
                )
            } catch (_: Exception) {
                // 单个变体拉不到就跳过，不让整个展开失败。
            }
        }
        if (out.isEmpty()) {
            throw ExtractException.ParseFailed("master 下所有变体都拉不到：${master.url}")
        }
        return out
    }

    override fun selectVariant(
        variants: List<Variant>,
        policy: VariantPolicy,
    ): Variant {
        if (variants.isEmpty()) throw ExtractException.VariantNotFound("变体表为空")
        return when (policy) {
            VariantPolicy.HIGHEST_BANDWIDTH -> variants.maxByOrNull { it.bandwidth }!!
            VariantPolicy.LOWEST_BANDWIDTH -> variants.minByOrNull { it.bandwidth }!!
            VariantPolicy.PREFER_720P -> {
                variants.minByOrNull { v ->
                    val h = v.resolution.substringAfter('x', "").toIntOrNull() ?: 0
                    kotlin.math.abs(h - 720)
                } ?: variants.maxByOrNull { it.bandwidth }!!
            }
        }
    }

    override fun mediaOf(graph: PlaylistGraph, variant: Variant?): MediaPlaylist {
        return graph.media ?: MediaPlaylist(url = graph.url, segments = emptyList())
    }

    override fun isLive(playlist: MediaPlaylist): Boolean = playlist.isLive

    override fun initSegmentOf(playlist: MediaPlaylist): InitSegment? {
        return playlist.initSegment
    }

    override fun parseSegments(playlist: MediaPlaylist): List<Segment> {
        return playlist.segments
    }

    override fun resolveUri(baseUri: String, reference: String): String {
        return HlsPlaylistKt.resolveUri(baseUri, reference)
    }

    override fun absolutize(playlist: MediaPlaylist): MediaPlaylist {
        val segments = playlist.segments.map { s ->
            s.copy(url = resolveUri(playlist.url, s.url))
        }
        val init = playlist.initSegment?.copy(url = resolveUri(playlist.url, playlist.initSegment.url))
        return playlist.copy(segments = segments, initSegment = init)
    }

    override fun planRequests(
        segments: List<Segment>,
        ctx: ExtractContext,
    ): List<SegmentRequest> {
        val headers = mutableMapOf<String, String>()
        headers.putAll(ctx.headers)
        ctx.referer?.let { headers["Referer"] = it }
        if (ctx.cookies.isNotEmpty()) {
            headers["Cookie"] = ctx.cookies.joinToString("; ")
        }
        return segments.map { s ->
            SegmentRequest(
                url = s.url,
                headers = headers,
                byteRangeLength = s.byteRangeLength,
                byteRangeOffset = s.byteRangeOffset,
            )
        }
    }

    override fun encryptionOf(playlist: MediaPlaylist): List<EncryptionInfo> {
        return playlist.segments.mapNotNull { it.key }.distinct()
    }

    override suspend fun fetchKey(ref: KeyRef, ctx: ExtractContext): KeyMaterial {
        ensureOpen()
        val bytes = fetchBytes(ref.uri, ctx)
        return KeyMaterial(bytes = bytes, method = ref.method)
    }

    override fun deriveIv(
        sequence: Long,
        explicitIv: ByteArray?,
        key: KeyMaterial,
    ): ByteArray {
        if (explicitIv != null) return explicitIv
        val iv = ByteArray(16)
        var n = sequence
        for (i in 15 downTo 8) {
            iv[i] = (n and 0xff).toByte()
            n = n shr 8
        }
        return iv
    }

    override fun decrypt(
        data: ByteArray,
        key: KeyMaterial,
        iv: ByteArray,
        method: EncryptionMethod,
    ): ByteArray {
        return when (method) {
            EncryptionMethod.NONE -> data
            EncryptionMethod.AES_128 -> {
                if (key.bytes.size != 16) {
                    throw ExtractException.DecryptFailed("AES-128 密钥必须是 16 字节")
                }
                if (iv.size != 16) {
                    throw ExtractException.DecryptFailed("IV 必须是 16 字节")
                }
                try {
                    val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
                    cipher.init(
                        Cipher.DECRYPT_MODE,
                        SecretKeySpec(key.bytes, "AES"),
                        IvParameterSpec(iv),
                    )
                    cipher.doFinal(data)
                } catch (e: Exception) {
                    throw ExtractException.DecryptFailed("AES 解密失败：${e.message}")
                }
            }
            EncryptionMethod.SAMPLE_AES, EncryptionMethod.UNKNOWN -> {
                throw ExtractException.DecryptFailed("不支持的加密方式：$method")
            }
        }
    }

    override suspend fun decryptSegment(
        segment: Segment,
        key: KeyMaterial,
        iv: ByteArray,
        ctx: ExtractContext,
    ): ByteArray {
        ensureOpen()
        val bytes = fetchBytes(segment.url, ctx, segment)
        val method = when (segment.key?.method) {
            "NONE" -> EncryptionMethod.NONE
            "AES-128" -> EncryptionMethod.AES_128
            "SAMPLE-AES" -> EncryptionMethod.SAMPLE_AES
            else -> EncryptionMethod.UNKNOWN
        }
        return decrypt(bytes, key, iv, method)
    }

    override fun extractUrls(input: ExtractorInput, spec: UrlSpec): List<ExtractedUrl> {
        val raw = AdapterPipeline.extractMediaUrls(input.text, input.baseUrl)
        return raw.mapNotNull { url ->
            if (!matchesSpec(url, spec)) return@mapNotNull null
            ExtractedUrl(url, classify(url, null))
        }
    }

    override fun extractUrls(node: JSONObject, spec: UrlSpec): List<ExtractedUrl> {
        val found = LinkedHashSet<String>()
        collectJsonUrls(node, found)
        return found.mapNotNull { url ->
            if (!matchesSpec(url, spec)) return@mapNotNull null
            val kind = classify(url, null)
            if (kind == UrlKind.PLAYLIST || kind == UrlKind.MEDIA) {
                ExtractedUrl(url, kind)
            } else {
                null
            }
        }
    }

    override fun extractUrls(
        attributes: Map<String, String>,
        spec: UrlSpec,
    ): List<ExtractedUrl> {
        val found = LinkedHashSet<String>()
        for ((_, value) in attributes) {
            found += AdapterPipeline.extractMediaUrls(value, "")
            if (value.startsWith("http://") || value.startsWith("https://")) {
                found += value
            }
        }
        return found.mapNotNull { url ->
            if (!matchesSpec(url, spec)) return@mapNotNull null
            val kind = classify(url, null)
            if (kind == UrlKind.PLAYLIST || kind == UrlKind.MEDIA) {
                ExtractedUrl(url, kind)
            } else {
                null
            }
        }
    }

    override fun normalize(url: String, baseUri: String?): String? {
        return try {
            val resolved = if (baseUri != null) {
                java.net.URI(baseUri).resolve(url).toString()
            } else {
                url
            }
            val uri = java.net.URI(resolved)
            if (uri.scheme != "http" && uri.scheme != "https") return null
            uri.toString().substringBefore('#')
        } catch (_: Exception) {
            null
        }
    }

    override fun classify(url: String, mime: String?, magic: ByteArray?): UrlKind {
        val m = mime?.lowercase()
        if (m != null) {
            if (m.contains("mpegurl") || m.contains("dash+xml")) return UrlKind.PLAYLIST
            if (m.startsWith("video/") || m.startsWith("audio/")) return UrlKind.MEDIA
            if (m.startsWith("image/") || m == "text/html") return UrlKind.OTHER
        }
        if (magic != null && magic.size >= 4) {
            if (magic[0] == '#'.code.toByte() && magic[1] == 'E'.code.toByte() &&
                magic[2] == 'X'.code.toByte()
            ) {
                return UrlKind.PLAYLIST
            }
            // ftyp box: bytes 4..7 == "ftyp"
            if (magic[4] == 'f'.code.toByte() && magic[5] == 't'.code.toByte() &&
                magic[6] == 'y'.code.toByte() && magic[7] == 'p'.code.toByte()
            ) {
                return UrlKind.MEDIA
            }
        }
        return when (RequestRecorder.classify(url)) {
            RequestRecorder.UrlKind.PLAYLIST -> UrlKind.PLAYLIST
            RequestRecorder.UrlKind.MEDIA -> UrlKind.MEDIA
            RequestRecorder.UrlKind.PAGE -> UrlKind.PAGE
            RequestRecorder.UrlKind.OTHER -> UrlKind.OTHER
        }
    }

    override fun toCandidate(url: ExtractedUrl, ctx: ExtractContext): DownloadCandidate? {
        if (url.kind != UrlKind.PLAYLIST && url.kind != UrlKind.MEDIA) return null
        return DownloadCandidate(
            url = url.url,
            headers = ctx.headers,
            referer = ctx.referer,
            cookies = ctx.cookies,
            mime = url.mime,
            confidence = CandidateNormalizer.baseScore(CandidateSource.RULE),
            source = CandidateSource.RULE,
        )
    }

    override fun score(candidate: DownloadCandidate, ctx: ExtractContext): Float {
        return CandidateNormalizer.normalize(candidate)?.confidence ?: 0f
    }

    override fun dedupe(candidates: List<DownloadCandidate>): List<DownloadCandidate> {
        return CandidateNormalizer.dedupe(candidates)
    }

    override suspend fun refresh(
        candidate: DownloadCandidate,
        ctx: ExtractContext,
    ): DownloadCandidate {
        ensureOpen()
        if (!candidate.url.lowercase().contains(".m3u8")) return candidate
        try {
            val text = fetchText(candidate.url, ctx)
            val graph = parsePlaylist(PlaylistPayload(text, candidate.url), ctx)
            val variant = runCatching {
                selectVariant(graph.variants, VariantPolicy.HIGHEST_BANDWIDTH)
            }.getOrNull()
            return candidate.copy(variant = variant ?: candidate.variant)
        } catch (e: Exception) {
            throw ExtractException.RefreshFailed("重取播放列表失败：${e.message}")
        }
    }

    override fun isExpired(candidate: DownloadCandidate, nowMs: Long): Boolean {
        val exp = candidate.expiresAt ?: return false
        return nowMs > exp
    }

    override fun close() {
        closed = true
    }

    // ---------- 内部 ----------

    private fun ensureOpen() {
        if (closed) throw ExtractException.Cancelled("Extractor 已关闭")
    }

    private fun matchesSpec(url: String, spec: UrlSpec): Boolean {
        if (spec.includePatterns.isNotEmpty() &&
            spec.includePatterns.none { url.contains(it) }
        ) {
            return false
        }
        if (spec.excludePatterns.any { url.contains(it) }) return false
        return true
    }

    private fun collectJsonUrls(node: Any, out: MutableSet<String>) {
        when (node) {
            is JSONObject -> {
                val keys = node.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val value = node.opt(key)
                    if (value is String) {
                        if (value.startsWith("http://") || value.startsWith("https://")) {
                            out += value
                        }
                        out += AdapterPipeline.extractMediaUrls(value, "")
                    } else if (value is JSONObject || value is JSONArray) {
                        collectJsonUrls(value, out)
                    }
                }
            }
            is JSONArray -> {
                for (i in 0 until node.length()) {
                    val value = node.opt(i)
                    if (value is String) {
                        if (value.startsWith("http://") || value.startsWith("https://")) {
                            out += value
                        }
                        out += AdapterPipeline.extractMediaUrls(value, "")
                    } else if (value is JSONObject || value is JSONArray) {
                        collectJsonUrls(value, out)
                    }
                }
            }
        }
    }

    private fun fetchText(url: String, ctx: ExtractContext): String {
        return fetchBytes(url, ctx).toString(Charsets.UTF_8)
    }

    private fun fetchBytes(
        url: String,
        ctx: ExtractContext,
        segment: Segment? = null,
    ): ByteArray {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = ctx.timeoutMs.toInt()
            readTimeout = ctx.timeoutMs.toInt()
            requestMethod = "GET"
            ctx.headers.forEach { (k, v) -> setRequestProperty(k, v) }
            ctx.referer?.let { setRequestProperty("Referer", it) }
            if (ctx.cookies.isNotEmpty()) {
                setRequestProperty("Cookie", ctx.cookies.joinToString("; "))
            }
            if (segment?.byteRangeLength != null) {
                val start = segment.byteRangeOffset ?: 0L
                val end = start + segment.byteRangeLength - 1
                setRequestProperty("Range", "bytes=$start-$end")
            }
            setRequestProperty("User-Agent", ctx.headers["User-Agent"] ?: DEFAULT_UA)
        }
        try {
            val code = conn.responseCode
            if (code != HttpURLConnection.HTTP_OK &&
                code != HttpURLConnection.HTTP_PARTIAL
            ) {
                throw ExtractException.KeyFetchFailed("HTTP $code：$url")
            }
            return conn.inputStream.use { it.readBytes() }
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        const val DEFAULT_UA =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    }
}
