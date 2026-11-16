package dev.akash.skystream.sniffer

/**
 * 候选归一器：打分、过滤、去重（D3 契约三条规则的 Kotlin 实现）。
 * 纯逻辑，不碰网络与 WebView。
 */
object CandidateNormalizer {

    /** 各来源的起始分（D3 打分规则）。 */
    fun baseScore(source: CandidateSource): Float {
        return when (source) {
            CandidateSource.NETWORK -> 0.9f
            CandidateSource.SERVICE_WORKER -> 0.85f
            CandidateSource.PAGE_SCRIPT -> 0.7f
            CandidateSource.VIDEO_LISTENER -> 0.6f
            CandidateSource.RULE -> 0.5f
            CandidateSource.BLOB_MSE -> 0.45f
            CandidateSource.DIRECT -> 0.9f
        }
    }

    /** 给一条候选打分并做过滤；低于 0.3 返回 null（不进 UI）。 */
    fun normalize(candidate: DownloadCandidate): DownloadCandidate? {
        var score = candidate.confidence
        val url = candidate.url.lowercase()
        if (RequestRecorder.looksLikeAdOrPreview(url)) score -= 0.4f
        if (candidate.mime != null &&
            (candidate.mime!!.startsWith("image/") ||
                candidate.mime == "text/html")
        ) {
            score -= 0.4f
        }
        val variant = candidate.variant
        if (variant != null) {
            if (variant.bandwidth in 1..299999) score -= 0.1f
            val res = variant.resolution
            if (res.isNotEmpty()) {
                val w = res.substringBefore('x').toIntOrNull() ?: 0
                val h = res.substringAfter('x', "").toIntOrNull() ?: 0
                if (w in 1..320 && h in 1..180) score -= 0.4f
            }
        }
        // Blob/MSE 推断的置信度上限 0.45（D3）。
        if (candidate.source == CandidateSource.BLOB_MSE && score > 0.45f) {
            score = 0.45f
        }
        score = score.coerceIn(0f, 1f)
        if (score < 0.3f) return null
        return candidate.copy(confidence = score)
    }

    /** 一级去重：同规范化 id 只留 confidence 最高者，来源合并。 */
    fun dedupe(candidates: List<DownloadCandidate>): List<DownloadCandidate> {
        val byId = LinkedHashMap<String, DownloadCandidate>()
        val sourcesById = HashMap<String, MutableSet<CandidateSource>>()
        for (c in candidates) {
            val sources = sourcesById.getOrPut(c.id) { mutableSetOf() }
            sources.add(c.source)
            val prev = byId[c.id]
            if (prev == null || c.confidence > prev.confidence) {
                byId[c.id] = c
            }
        }
        // 同 URL 多源命中：来源数 >= 2 时升权 0.05（上限 1.0）。
        return byId.values.map { c ->
            val n = sourcesById[c.id]?.size ?: 1
            if (n >= 2 && c.confidence < 1f) {
                c.copy(confidence = (c.confidence + 0.05f).coerceAtMost(1f))
            } else {
                c
            }
        }.sortedByDescending { it.confidence }
    }

    /** 规范化 URL：去 fragment、host 小写（去重键用）。 */
    fun normalizeUrl(url: String): String {
        return try {
            val uri = java.net.URI(url)
            val host = uri.host?.lowercase() ?: ""
            val sb = StringBuilder()
            if (uri.scheme != null) sb.append(uri.scheme).append("://")
            sb.append(host)
            if (uri.port != -1) sb.append(':').append(uri.port)
            sb.append(uri.rawPath ?: "")
            if (uri.rawQuery != null) sb.append('?').append(uri.rawQuery)
            sb.toString()
        } catch (_: Exception) {
            url.substringBefore('#').lowercase()
        }
    }
}
