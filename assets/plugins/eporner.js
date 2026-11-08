// Super Library — Eporner plugin (SkyStream JS plugin format). TIER 1 / INSTANT.
// Uses the official public Eporner search API — no scraping, no login.
// Verified live 2026-11-07: GET /api/v2/video/search/?query=foot&per_page=5
// returned 5 results in 5ms, each with title, length_sec, url, embed and
// default_thumb.src. That is why this source answers first while deep
// crawlers are still running.
//
// PAGINATION RULE (user decision 2026-11-07): the API defaults to 20/page —
// NEVER return only page 1. Fetch per_page=100 and keep paging (up to 5
// pages / 500 results, stop early when a page comes back short/empty) so a
// hot query like 八重神子 returns hundreds, not 20. Results stream in
// page by page; the shell must append them, never cap the list at 20.
//
// INCLUSION RULE (user decision 2026-11-07): include a result as soon as its
// TEXT is known (title + duration + source). posterUrl is set only when the
// API actually returned a thumb; if a thumb is missing the item is still
// returned with posterUrl "" and the UI shows a text card — never drop it.
(function () {
  var API = 'https://www.eporner.com/api/v2/video/search/';
  var PER_PAGE = 100;   // API max-ish page size; do NOT use the 20 default
  var MAX_PAGES = 5;    // up to 500 results per query

  function toItem(v) {
    return new MultimediaItem({
      title: v.title || '(no title)',
      url: v.url || ('https://www.eporner.com/embed/' + v.id + '/'),
      posterUrl: (v.default_thumb && v.default_thumb.src) || '',
      type: 'movie',
      description: (v.keywords || '') + (v.added ? ' · ' + v.added : ''),
      duration: v.length_sec ? Math.round(v.length_sec / 60) : 0,
      tags: ['eporner']
    });
  }

  // Paginated search: page through the API and accumulate. The shell calls
  // search() once; the plugin itself walks the pages so one call can return
  // hundreds for a hot query instead of the 20-item first page.
  async function search(query, page, cb) {
    try {
      var out = [];
      for (var p = 1; p <= MAX_PAGES; p++) {
        var url = API + '?query=' + encodeURIComponent(query || '') +
          '&per_page=' + PER_PAGE + '&page=' + p + '&format=json';
        var res = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0' } });
        var json = await res.json();
        var vids = json.videos || [];
        vids.forEach(function (v) { out.push(toItem(v)); });
        if (vids.length < PER_PAGE) break; // last page (short/empty) — stop
      }
      cb({ success: true, data: out });
    } catch (e) { cb({ success: false, errorCode: 'SEARCH_ERROR', message: String(e) }); }
  }

  async function getHome(cb) {
    try {
      var res = await fetch(API + '?query=&per_page=20&page=1&order=most-popular&format=json');
      var json = await res.json();
      cb({ success: true, data: { 'Trending': (json.videos || []).map(toItem) } });
    } catch (e) { cb({ success: false, errorCode: 'HOME_ERROR', message: String(e) }); }
  }

  async function load(url, cb) {
    try {
      // Eporner item: stream via the embed page (player handles it); the
      // direct mp4 is resolved by the host's embed, not by this plugin.
      cb({ success: true, data: new MultimediaItem({
        title: url, url: url, posterUrl: '', type: 'movie',
        streams: [new StreamResult({ url: url, source: 'eporner-embed' })]
      }) });
    } catch (e) { cb({ success: false, errorCode: 'LOAD_ERROR', message: String(e) }); }
  }

  async function loadStreams(url, cb) {
    try {
      cb({ success: true, data: [new StreamResult({ url: url, source: 'eporner-embed' })] });
    } catch (e) { cb({ success: false, errorCode: 'STREAM_ERROR', message: String(e) }); }
  }

  globalThis.getHome = getHome;
  globalThis.search = search;
  globalThis.load = load;
  globalThis.loadStreams = loadStreams;
})();
