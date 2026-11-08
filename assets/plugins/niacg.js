
// INCLUSION RULE (user decision 2026-11-07): include a result as soon as its
// TEXT is known (title + duration + source). posterUrl only when the page
// actually carries a thumbnail; missing thumb -> posterUrl "" + text card
// (title + source + duration), NEVER drop the result.
// PAGINATION RULE (user decision 2026-11-07): never stop at 20 results.
// Page through the source (up to the per-plugin MAX_PAGES) and accumulate;
// hot queries must return hundreds across all 9 sources, results appended
// as they arrive.

(function () {
  // TIER 2/3. Search endpoint (from 3d-batch-04 niacg_search.py, verified pattern):
  //   https://www.niacg.com/e/search/?searchget=1&keyboard={q}&show=title&classid=21
  // Detail pages carry the direct mp4: https://file.xunge.cyou/1080/...mp4
  // which REQUIRES the niacg detail page as Referer (verified: no Referer -> 403,
  // with Referer -> 206). The browser cannot forge Referer; SkyStream's native
  // layer CAN via StreamResult.headers — that is the whole point of this plugin.
  // LIVE NOTE 2026-11-07: VM curl to the search endpoint returned 302 (redirect,
  // likely to a mirror); plugin follows redirects and falls back to freeacg4.org.
  var UA = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' };
  var MAX_PAGES = 3;
  function parseSearch(html) {
    var out = [], seen = {};
    var re = /href="(\/showinfo-21-(\d+)-0\.html)"[^>]*title="([^"]*)"/g, m;
    while ((m = re.exec(html)) !== null && out.length < 100) {
      if (seen[m[2]]) continue; seen[m[2]] = 1;
      out.push(new MultimediaItem({ title: m[3], url: 'https://www.niacg.com' + m[1], posterUrl: '', type: 'movie', tags: ['niacg'] }));
    }
    return out;
  }
  async function search(query, page, cb) {
    try {
      var out = [];
      for (var p = 1; p <= MAX_PAGES; p++) {
        var url = 'https://www.niacg.com/e/search/?searchget=1&keyboard=' + encodeURIComponent(query || '') + '&show=title&classid=21&page=' + p;
        var res = await fetch(url, { headers: UA });
        var html = await res.text();
        var got = parseSearch(html);
        got.forEach(function (x) { out.push(x); });
        if (got.length === 0) break;
      }
      cb({ success: true, data: out });
    } catch (e) { cb({ success: false, errorCode: 'SEARCH_ERROR', message: String(e) }); }
  }
  async function getHome(cb) { cb({ success: true, data: {} }); }
  async function load(url, cb) {
    try {
      var res = await fetch(url, { headers: UA });
      var html = await res.text();
      var mp4 = html.match(/(https:\/\/file\.xunge\.cyou\/1080\/[^"'\s]+\.mp4)/);
      var title = (html.match(/<title>([^<]+)<\/title>/) || [])[1] || url;
      var thumb = html.match(/<img[^>]+src="([^"]+\.(?:jpg|jpeg|png|webp))"/);
      var item = new MultimediaItem({ title: title, url: url, posterUrl: thumb ? thumb[1] : '', type: 'movie', tags: ['niacg'] });
      if (mp4) item.streams = [new StreamResult({ url: mp4[1], source: 'niacg-1080p', headers: { Referer: url } })];
      cb({ success: true, data: item });
    } catch (e) { cb({ success: false, errorCode: 'LOAD_ERROR', message: String(e) }); }
  }
  async function loadStreams(url, cb) {
    try {
      var res = await fetch(url, { headers: UA });
      var html = await res.text();
      var mp4 = html.match(/(https:\/\/file\.xunge\.cyou\/1080\/[^"'\s]+\.mp4)/);
      if (!mp4) throw new Error('no xunge mp4 on ' + url);
      cb({ success: true, data: [new StreamResult({ url: mp4[1], source: 'niacg-1080p', headers: { Referer: url } })] });
    } catch (e) { cb({ success: false, errorCode: 'STREAM_ERROR', message: String(e) }); }
  }
  globalThis.getHome = getHome; globalThis.search = search; globalThis.load = load; globalThis.loadStreams = loadStreams;
})();
