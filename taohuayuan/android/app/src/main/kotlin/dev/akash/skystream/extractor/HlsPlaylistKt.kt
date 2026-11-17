package dev.akash.skystream.extractor

import dev.akash.skystream.sniffer.EncryptionInfo
import dev.akash.skystream.sniffer.Variant

/**
 * HLS 播放列表解析器（Kotlin 版，与 Dart 侧 lib/transfer/hls_playlist.dart
 * 同一套解析规则：master 变体、KEY（METHOD/URI/IV）、MAP、BYTERANGE、
 * MEDIA-SEQUENCE、直播判定）。
 */
object HlsPlaylistKt {

    fun isMaster(text: String): Boolean = text.contains("#EXT-X-STREAM-INF")

    fun parseMaster(text: String, base: String): List<Variant> {
        val result = mutableListOf<Variant>()
        val lines = text.split(Regex("\r?\n"))
        var i = 0
        while (i < lines.size) {
            val line = lines[i].trim()
            if (!line.startsWith("#EXT-X-STREAM-INF")) {
                i++
                continue
            }
            val bandwidth = Regex("""BANDWIDTH=(\d+)""").find(line)?.groupValues?.getOrNull(1)
                ?.toLongOrNull() ?: 0L
            val resolution = Regex("""RESOLUTION=([^,\s]+)""").find(line)?.groupValues?.getOrNull(1) ?: ""
            val codecs = Regex("""CODECS="([^"]*)"""").find(line)?.groupValues?.getOrNull(1) ?: ""
            var j = i + 1
            while (j < lines.size &&
                (lines[j].trim().isEmpty() || lines[j].trim().startsWith("#"))
            ) {
                j++
            }
            if (j < lines.size) {
                result.add(
                    Variant(
                        resolution = resolution,
                        bandwidth = bandwidth,
                        codecs = codecs,
                        url = resolveUri(base, lines[j].trim()),
                    ),
                )
                i = j
            }
            i++
        }
        return result
    }

    fun parseMedia(text: String, base: String): MediaPlaylist {
        val segments = mutableListOf<Segment>()
        var mapUri: String? = null
        var isLive = true
        var mediaSequence = 0L
        var currentKey: EncryptionInfo? = null
        var durationMs: Long? = null
        var pendingRangeLength: Long? = null
        var pendingRangeOffset: Long? = null
        var nextOffset = 0L
        var sequence = 0L
        var sequenceSet = false

        fun attrValue(line: String, name: String): String? {
            Regex("""$name="([^"]*)"""").find(line)?.groupValues?.getOrNull(1)?.let { return it }
            return Regex("""$name=([^,\s]+)""").find(line)?.groupValues?.getOrNull(1)
        }

        for (raw in text.split(Regex("\r?\n"))) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            when {
                line.startsWith("#EXT-X-ENDLIST") -> isLive = false
                line.startsWith("#EXT-X-MEDIA-SEQUENCE") -> {
                    mediaSequence = line.substringAfter(':').trim().toLongOrNull() ?: 0L
                    if (!sequenceSet) {
                        sequence = mediaSequence
                        sequenceSet = true
                    }
                }
                line.startsWith("#EXT-X-MAP") -> {
                    attrValue(line, "URI")?.let { mapUri = resolveUri(base, it) }
                }
                line.startsWith("#EXT-X-KEY") -> {
                    val method = attrValue(line, "METHOD") ?: ""
                    val uri = attrValue(line, "URI")
                    val ivRaw = attrValue(line, "IV")
                    currentKey = EncryptionInfo(
                        method = method,
                        uri = if (uri == null) "" else resolveUri(base, uri),
                        iv = if (ivRaw == null) null else parseIv(ivRaw),
                    )
                }
                line.startsWith("#EXT-X-BYTERANGE") -> {
                    val value = line.substringAfter(':').trim()
                    val parts = value.split("@")
                    pendingRangeLength = parts[0].toLongOrNull()
                    pendingRangeOffset = if (parts.size > 1) {
                        parts[1].toLongOrNull()
                    } else {
                        nextOffset
                    }
                }
                line.startsWith("#EXTINF") -> {
                    val afterColon = line.substringAfter(':')
                    durationMs = ((afterColon.split(',').first().trim().toDoubleOrNull() ?: 0.0) * 1000).toLong()
                }
                !line.startsWith("#") -> {
                    val length = pendingRangeLength
                    val offset = pendingRangeOffset
                    if (length != null && offset != null) {
                        nextOffset = offset + length
                    }
                    segments.add(
                        Segment(
                            url = resolveUri(base, line),
                            durationMs = durationMs ?: 0L,
                            sequence = sequence,
                            key = currentKey,
                            byteRangeLength = length,
                            byteRangeOffset = offset,
                        ),
                    )
                    sequence++
                    durationMs = null
                    pendingRangeLength = null
                    pendingRangeOffset = null
                }
            }
        }
        return MediaPlaylist(
            url = base,
            segments = segments,
            initSegment = mapUri?.let { InitSegment(url = it) },
            isLive = isLive,
            mediaSequence = mediaSequence,
            totalDurationMs = segments.sumOf { it.durationMs },
        )
    }

    fun pickVariant(variants: List<Variant>): Variant? {
        return variants.maxByOrNull { it.bandwidth }
    }

    /** 解析 IV=0x... 十六进制串；不合法返回 null。 */
    fun parseIv(raw: String): ByteArray? {
        var hex = raw.trim()
        if (hex.lowercase().startsWith("0x")) hex = hex.substring(2)
        if (hex.isEmpty() || hex.length % 2 != 0) return null
        if (!Regex("^[0-9a-fA-F]+$").matches(hex)) return null
        val out = ByteArray(hex.length / 2)
        for (i in out.indices) {
            out[i] = hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
        return out
    }

    fun resolveUri(baseUri: String, reference: String): String {
        return try {
            java.net.URI(baseUri).resolve(reference).toString()
        } catch (_: Exception) {
            reference
        }
    }
}
