
// INCLUSION RULE (user decision 2026-11-07): include a result as soon as its
// TEXT is known (title + duration + source). posterUrl only when the page
// actually carries a thumbnail; missing thumb -> posterUrl "" + text card
// (title + source + duration), NEVER drop the result.
// PAGINATION RULE (user decision 2026-11-07): never stop at 20 results.
// Page through the source (up to the per-plugin MAX_PAGES) and accumulate;
// hot queries must return hundreds across all 9 sources, results appended
// as they arrive.

(function () {
  // TIER 2. WordPress site "恋足" — search ?s={q}, detail pages carry direct mp4
  // (media.lianzu11.com / 66843.gyujmnb.net), NO Referer required, Range OK.
  // 21 verified entries (110 min, 20x true 1080p) in 3d-batch-08 lianzu11 probe.
  // LIVE NOTE 2026-11-07: VM curl to lianzu11.com returned 000 (no route from
  // this VM at probe time) — plugin logic is written from the verified probe
  // data; re-verify from the phone/app network before calling it "working".
  var UA = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' };
  var MAX_PAGES = 3;
  function parseSearch(html) {
    var out = [], seen = {};
    var re = /<a[^>]+href="(https:\/\/lianzu11\.com\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/g, m;
    while ((m = re.exec(html)) !== null && out.length < 100) {
      if (seen[m[1]] || /page\/|category|tag\//.test(m[1])) continue;
      var img = m[2].match(/<img[^>]+(?:data-src|src)="([^"]+)"/);
      var text = m[2].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
      if (!text) continue;
      seen[m[1]] = 1;
      out.push(new MultimediaItem({ title: text.slice(0, 120), url: m[1], posterUrl: img ? img[1] : '', type: 'movie', tags: ['lianzu11'] }));
    }
    return out;
  }
  async function search(query, page, cb) {
    try {
      var out = [];
      for (var p = 1; p <= MAX_PAGES; p++) {
        var url = 'https://lianzu11.com/' + (p > 1 ? 'page/' + p + '/' : '') + '?s=' + encodeURIComponent(query || '');
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
    try {
      var res = await fetch(url, { headers: UA });
      var html = await res.text();
      var mp4 = html.match(/(https:\/\/(?:media\.lianzu11\.com|66843\.gyujmnb\.net)\/[^"'\s]+\.mp4)/) || html.match(/(https:\/\/[^"'\s]+\.mp4)/);
      var title = (html.match(/<title>([^<]+)<\/title>/) || [])[1] || url;
      var item = new MultimediaItem({ title: title, url: url, posterUrl: '', type: 'movie', tags: ['lianzu11'] });
      if (mp4) item.streams = [new StreamResult({ url: mp4[1], source: 'lianzu11-1080p' })];
      cb({ success: true, data: item });
    } catch (e) { cb({ success: false, errorCode: 'LOAD_ERROR', message: String(e) }); }
  }
  async function loadStreams(url, cb) {
    try {
      var res = await fetch(url, { headers: UA });
      var html = await res.text();
      var mp4 = html.match(/(https:\/\/(?:media\.lianzu11\.com|66843\.gyujmnb\.net)\/[^"'\s]+\.mp4)/) || html.match(/(https:\/\/[^"'\s]+\.mp4)/);
      if (!mp4) throw new Error('no mp4 on ' + url);
      cb({ success: true, data: [new StreamResult({ url: mp4[1], source: 'lianzu11-1080p' })] });
    } catch (e) { cb({ success: false, errorCode: 'STREAM_ERROR', message: String(e) }); }
  }
  globalThis.getHome = getHome; globalThis.search = search; globalThis.load = load; globalThis.loadStreams = loadStreams;
})();
