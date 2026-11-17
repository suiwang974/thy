package dev.akash.skystream.sniffer

/**
 * 六路适配器管线：把捕获层的原始记录归一为 DownloadCandidate（D3 契约）。
 * 通用实现，不含站点定制逻辑；新加源不改这里。
 * 上线顺序按 config.adapterOrder；每路产出经 CandidateNormalizer 打分去重。
 */
class AdapterPipeline(private val config: SniffConfig) {

    /** 页内脚本上报的一条请求记录（URL + 方法 + 响应文本片段）。 */
    data class PageScriptReport(
        val url: String,
        val method: String = "GET",
        val bodySnippet: String = "",
    )

    /** Blob 事件（createObjectURL 上报）。 */
    data class BlobEvent(val url: String, val kind: String = "")

    data class Inputs(
        val pageUrl: String = "",
        val requests: List<InterceptedRequest> = emptyList(),
        val pageScriptReports: List<PageScriptReport> = emptyList(),
        val media: List<MediaSnapshot> = emptyList(),
        val blobEvents: List<BlobEvent> = emptyList(),
        val mseActive: Boolean = false,
        val resourceUrls: List<String> = emptyList(),
    )

    fun run(inputs: Inputs): List<DownloadCandidate> {
        val out = mutableListOf<DownloadCandidate>()
        for (source in config.adapterOrder) {
            when (source) {
                CandidateSource.NETWORK -> out += networkAdapter(inputs)
                CandidateSource.SERVICE_WORKER -> out += serviceWorkerAdapter(inputs)
                CandidateSource.PAGE_SCRIPT -> out += pageScriptAdapter(inputs)
                CandidateSource.VIDEO_LISTENER -> out += videoListenerAdapter(inputs)
                CandidateSource.RULE -> out += ruleAdapter(inputs)
                CandidateSource.BLOB_MSE -> out += blobMseAdapter(inputs)
                CandidateSource.DIRECT -> Unit
            }
        }
        return CandidateNormalizer.dedupe(
            out.mapNotNull { CandidateNormalizer.normalize(it) },
        ).take(config.maxCandidates)
    }

    /** 网络层：shouldInterceptRequest 记到的 playlist / 媒体直链。 */
    private fun networkAdapter(inputs: Inputs): List<DownloadCandidate> {
        return inputs.requests.mapNotNull { req ->
            val kind = RequestRecorder.classify(req.url)
            if (kind != RequestRecorder.UrlKind.PLAYLIST &&
                kind != RequestRecorder.UrlKind.MEDIA
            ) {
                return@mapNotNull null
            }
            DownloadCandidate(
                url = req.url,
                headers = req.headers,
                referer = req.headers["Referer"] ?: req.headers["referer"],
                confidence = CandidateNormalizer.baseScore(CandidateSource.NETWORK),
                source = CandidateSource.NETWORK,
            )
        }
    }

    /**
     * ServiceWorker 路：shouldInterceptRequest 看不到 SW 流量，
     * 用页内 performance 资源列表补——列表里有、网络记录里没有的
     * playlist/媒体地址，记为 SW 来源。
     */
    private fun serviceWorkerAdapter(inputs: Inputs): List<DownloadCandidate> {
        val seen = inputs.requests.map { it.url }.toSet()
        return inputs.resourceUrls.filter { it !in seen }.mapNotNull { url ->
            val kind = RequestRecorder.classify(url)
            if (kind != RequestRecorder.UrlKind.PLAYLIST &&
                kind != RequestRecorder.UrlKind.MEDIA
            ) {
                return@mapNotNull null
            }
            DownloadCandidate(
                url = url,
                confidence = CandidateNormalizer.baseScore(CandidateSource.SERVICE_WORKER),
                source = CandidateSource.SERVICE_WORKER,
            )
        }
    }

    /** 页内脚本路：XHR/fetch 上报的 URL 本身是 playlist/媒体时直接成候选。 */
    private fun pageScriptAdapter(inputs: Inputs): List<DownloadCandidate> {
        return inputs.pageScriptReports.mapNotNull { rep ->
            val kind = RequestRecorder.classify(rep.url)
            if (kind != RequestRecorder.UrlKind.PLAYLIST &&
                kind != RequestRecorder.UrlKind.MEDIA
            ) {
                return@mapNotNull null
            }
            DownloadCandidate(
                url = rep.url,
                confidence = CandidateNormalizer.baseScore(CandidateSource.PAGE_SCRIPT),
                source = CandidateSource.PAGE_SCRIPT,
            )
        }
    }

    /** video 监听路：video/audio/source 的 currentSrc。 */
    private fun videoListenerAdapter(inputs: Inputs): List<DownloadCandidate> {
        return inputs.media.mapNotNull { m ->
            val url = m.currentSrc?.takeIf { it.isNotEmpty() } ?: m.url
            if (url.isEmpty() || url.startsWith("blob:")) return@mapNotNull null
            DownloadCandidate(
                url = url,
                confidence = CandidateNormalizer.baseScore(CandidateSource.VIDEO_LISTENER),
                source = CandidateSource.VIDEO_LISTENER,
            )
        }
    }

    /**
     * 规则拼接路（通用 URL 抽取）：从 XHR/fetch 响应文本片段里抽
     * playlist/媒体地址（绝对地址与站内相对地址），不写站点定制规则。
     */
    private fun ruleAdapter(inputs: Inputs): List<DownloadCandidate> {
        val found = LinkedHashSet<String>()
        for (rep in inputs.pageScriptReports) {
            if (rep.bodySnippet.isEmpty()) continue
            found += extractMediaUrls(rep.bodySnippet, inputs.pageUrl)
        }
        return found.map { url ->
            DownloadCandidate(
                url = url,
                confidence = CandidateNormalizer.baseScore(CandidateSource.RULE),
                source = CandidateSource.RULE,
            )
        }
    }

    /**
     * Blob/MSE 路：MSE 激活时，performance 列表里的媒体/playlist 地址
     * 就是 MSE 背后真正的分片来源（blob: URL 本身下不了，不出候选）。
     * MSE 未激活或无对应资源地址时本路零产出。
     */
    private fun blobMseAdapter(inputs: Inputs): List<DownloadCandidate> {
        if (!inputs.mseActive) return emptyList()
        if (inputs.blobEvents.isEmpty()) return emptyList()
        val seen = inputs.requests.map { it.url }.toSet()
        return inputs.resourceUrls.filter { it !in seen }.mapNotNull { url ->
            val kind = RequestRecorder.classify(url)
            if (kind != RequestRecorder.UrlKind.PLAYLIST &&
                kind != RequestRecorder.UrlKind.MEDIA
            ) {
                return@mapNotNull null
            }
            DownloadCandidate(
                url = url,
                confidence = CandidateNormalizer.baseScore(CandidateSource.BLOB_MSE),
                source = CandidateSource.BLOB_MSE,
            )
        }
    }

    companion object {
        private val ABSOLUTE_URL = Regex("""https?://[^\s"'<>\\]+""")
        private val RELATIVE_MEDIA =
            Regex("""["'](/[^"'\s]+\.(?:m3u8|m3u|mpd|mp4|webm|ts|m4s))["']""")
        private val MEDIA_SUFFIX =
            Regex("""\.(m3u8|m3u|mpd|mp4|webm|ts|m4s)(\?[^#\s]*)?(#.*)?$""")

        /** 从文本里抽媒体地址；相对地址按 pageUrl 拼绝对地址。 */
        fun extractMediaUrls(text: String, pageUrl: String): List<String> {
            val out = LinkedHashSet<String>()
            for (m in ABSOLUTE_URL.findAll(text)) {
                val url = m.value.trimEnd(',', ';')
                if (MEDIA_SUFFIX.containsMatchIn(url.lowercase())) out += url
            }
            if (pageUrl.isNotEmpty()) {
                for (m in RELATIVE_MEDIA.findAll(text)) {
                    val rel = m.groupValues[1]
                    try {
                        out += java.net.URI(pageUrl).resolve(rel).toString()
                    } catch (_: Exception) {
                    }
                }
            }
            return out.toList()
        }
    }
}
