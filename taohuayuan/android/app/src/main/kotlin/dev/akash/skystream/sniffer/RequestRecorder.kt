package dev.akash.skystream.sniffer

/**
 * 网络请求记录器：定长环形缓冲 + URL 分类。
 * 记录来自 WebViewClient.shouldInterceptRequest（主线程回调）与页内脚本上报。
 * 只做记录与分类，不改请求、不拦请求。
 */
class RequestRecorder(private val maxSize: Int = 2000) {

    enum class UrlKind { PLAYLIST, MEDIA, PAGE, OTHER }

    private val lock = Any()
    private val buffer = ArrayDeque<InterceptedRequest>()

    fun record(request: InterceptedRequest) {
        synchronized(lock) {
            if (buffer.size >= maxSize) buffer.removeFirst()
            buffer.addLast(request)
        }
    }

    /** 取出并清空缓冲（供 AdapterPipeline 每轮消费）。 */
    fun drain(): List<InterceptedRequest> {
        synchronized(lock) {
            val out = buffer.toList()
            buffer.clear()
            return out
        }
    }

    /** 不清空，只看当前缓冲快照。 */
    fun snapshot(): List<InterceptedRequest> {
        synchronized(lock) {
            return buffer.toList()
        }
    }

    fun size(): Int {
        synchronized(lock) {
            return buffer.size
        }
    }

    fun clear() {
        synchronized(lock) {
            buffer.clear()
        }
    }

    companion object {
        private val PLAYLIST_EXT = listOf(".m3u8", ".m3u", ".mpd")
        private val MEDIA_EXT = listOf(
            ".mp4", ".webm", ".mkv", ".mov", ".m4v",
            ".ts", ".m4s", ".m4a", ".mp3", ".aac", ".flv",
        )

        fun classify(url: String): UrlKind {
            val lower = url.lowercase().substringBefore('?').substringBefore('#')
            if (PLAYLIST_EXT.any { lower.endsWith(it) }) return UrlKind.PLAYLIST
            if (MEDIA_EXT.any { lower.endsWith(it) }) return UrlKind.MEDIA
            val path = lower.substringAfter("://").substringAfter('/', "")
            if (path.isEmpty() || lower.endsWith(".html") || lower.endsWith(".htm") ||
                lower.endsWith(".php") || lower.endsWith(".aspx") ||
                lower.endsWith(".jsp") || lower.endsWith("/")
            ) {
                return UrlKind.PAGE
            }
            return UrlKind.OTHER
        }

        /** 播放列表/媒体地址里常见的广告与预览特征（打分时扣分用）。 */
        fun looksLikeAdOrPreview(url: String): Boolean {
            val lower = url.lowercase()
            return listOf("ad", "sprite", "thumb", "preview", "banner", "poster")
                .any { lower.contains(it) }
        }
    }
}
