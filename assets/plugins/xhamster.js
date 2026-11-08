
// INCLUSION RULE (user decision 2026-11-07): include a result as soon as its
// TEXT is known (title + duration + source). posterUrl only when the page
// actually carries a thumbnail; missing thumb -> posterUrl "" + text card
// (title + source + duration), NEVER drop the result.
// PAGINATION RULE (user decision 2026-11-07): never stop at 20 results.
// Page through the source (up to the per-plugin MAX_PAGES) and accumulate;
// hot queries must return hundreds across all 9 sources, results appended
// as they arrive.

(function () {
  // TIER 2. Search page verified pattern only — see README status table for
  // live verification state of this source (not all were re-probed live).
  var UA = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' };
  var MAX_PAGES = 3;
  function parseSearch(html) {
    var out = [], seen = {};
    var re = /<a[^>]+href="(https:\/\/xhamster\.com\/videos\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/g, m;
    while ((m = re.exec(html)) !== null && out.length < 100) {
      if (seen[m[1]]) continue; seen[m[1]] = 1;
      var img = (m[2] || '').match(/<img[^>]+(?:data-src|src)="([^"]+)"/);
      var text = (m[2] || '').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
      var title = (m[3] || text || m[1]).slice(0, 120);
      out.push(new MultimediaItem({ title: title, url: (m[1].indexOf('http') === 0 ? m[1] : 'https://xhamster.com' + m[1]), posterUrl: img ? img[1] : '', type: 'movie', tags: ['xhamster'] }));
    }
    return out;
  }
  async function search(query, page, cb) {
    try {
      var out = [];
      for (var p = 1; p <= MAX_PAGES; p++) {
        var url = 'https://xhamster.com/search/{{q}}?pagenumber={{p}}'.replace('{q}', encodeURIComponent(query || '')).replace('{p}', p);
        var res = await fetch(url, { headers: UA });
        var got = parseSearch(await res.text());
        got.forEach(function (x) { out.push(x); });
        if (got.length === 0) break;
      }
      cb({ success: true, data: out });
    } catch (e) { cb({ success: false, errorCode: 'SEARCH_ERROR', message: String(e) }); }
  }
  async function getHome(cb) { cb({ success: true, data: {} }); }
  async function load(url, cb) {
    try { cb({ success: true, data: new MultimediaItem({ title: url, url: url, posterUrl: '', type: 'movie', tags: ['xhamster'] }) }); }
    catch (e) { cb({ success: false, errorCode: 'LOAD_ERROR', message: String(e) }); }
  }
  async function loadStreams(url, cb) {
    // These hosts resolve the playable URL from the video page (embed/JS);
    // the shell falls back to WebView "在源站看" when no direct stream is found.
    try { cb({ success: true, data: [new StreamResult({ url: url, source: 'xhamster-page' })] }); }
    catch (e) { cb({ success: false, errorCode: 'STREAM_ERROR', message: String(e) }); }
  }
  globalThis.getHome = getHome; globalThis.search = search; globalThis.load = load; globalThis.loadStreams = loadStreams;
})();
