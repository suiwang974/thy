// Super Library — Rule34Video / r34content plugin (SkyStream JS plugin format).
// TIER 2 / DEEP. Search page verified live 2026-11-07:
//   GET https://rule34-videos.com/search/?q=foot -> HTTP 200, ~80 KB HTML.
// Detail pages expose master.m3u8 HLS (https://r34content.b-cdn.net/videos/<id>/master.m3u8)
// which needs NO Referer — direct playback works (this is how batches 01/02
// were downloaded: 15 segments, all HLS).
//
// INCLUSION RULE (user decision 2026-11-07): include a result as soon as its
// TEXT is known. posterUrl only when the search HTML actually carries a
// thumbnail; missing thumb -> posterUrl "" + text card, never drop the result.
(function () {
  var BASE = 'https://rule34-videos.com';
  var UA = { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' };

  function parseSearch(html) {
    var out = [];
    // NOTE: this site emits UNQUOTED hrefs: <a href=/video/slug> ... <img alt="title" data-thumbnails="...webp,...">
    var re = /<a[^>]+href=(?:"(\/video\/[^"]+)"|(\/video\/[^>\s]+))[^>]*>([\s\S]*?)<\/a>/g, m;
    while ((m = re.exec(html)) !== null && out.length < 100) {
      var href = m[1] || m[2], inner = m[3] || '';
      var alt = inner.match(/alt="([^"]+)"/);
      var thumbs = inner.match(/data-thumbnails=([^ >]+)/);
      var img = inner.match(/<img[^>]+(?:data-src|src)="([^"]+)"/);
      var poster = '';
      if (thumbs) poster = BASE + thumbs[1].split(',')[0];
      else if (img) poster = img[1].indexOf('http') === 0 ? img[1] : BASE + img[1];
      var dur = inner.match(/(\d+:\d{2})/);
      var text = inner.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
      out.push(new MultimediaItem({
        title: (alt && alt[1]) || text.slice(0, 80) || href,
        url: BASE + href,
        posterUrl: poster,
        type: 'movie',
        description: dur ? dur[1] : '',
        tags: ['rule34-videos']
      }));
    }
    return out;
  }

  async function search(query, page, cb) {
    try {
      var res = await fetch(BASE + '/search/?q=' + encodeURIComponent(query || ''), { headers: UA });
      var html = await res.text();
      cb({ success: true, data: parseSearch(html) });
    } catch (e) { cb({ success: false, errorCode: 'SEARCH_ERROR', message: String(e) }); }
  }

  async function getHome(cb) {
    try {
      var res = await fetch(BASE + '/', { headers: UA });
      cb({ success: true, data: { 'Trending': parseSearch(await res.text()) } });
    } catch (e) { cb({ success: false, errorCode: 'HOME_ERROR', message: String(e) }); }
  }

  async function load(url, cb) {
    try {
      var res = await fetch(url, { headers: UA });
      var html = await res.text();
      var m3u8 = html.match(/(https:\/\/r34content\.b-cdn\.net\/videos\/\d+\/master\.m3u8)/) ||
                  html.match(/(https:\/\/[^"']+\/master\.m3u8)/);
      var title = (html.match(/<title>([^<]+)<\/title>/) || [])[1] || url;
      var item = new MultimediaItem({ title: title, url: url, posterUrl: '', type: 'movie', tags: ['rule34-videos'] });
      if (m3u8) item.streams = [new StreamResult({ url: m3u8[1], source: 'r34-hls' })];
      cb({ success: true, data: item });
    } catch (e) { cb({ success: false, errorCode: 'LOAD_ERROR', message: String(e) }); }
  }

  async function loadStreams(url, cb) {
    try {
      var res = await fetch(url, { headers: UA });
      var html = await res.text();
      var m3u8 = html.match(/(https:\/\/r34content\.b-cdn\.net\/videos\/\d+\/master\.m3u8)/) ||
                  html.match(/(https:\/\/[^"']+\/master\.m3u8)/);
      if (!m3u8) throw new Error('no m3u8 found on ' + url);
      cb({ success: true, data: [new StreamResult({ url: m3u8[1], source: 'r34-hls' })] });
    } catch (e) { cb({ success: false, errorCode: 'STREAM_ERROR', message: String(e) }); }
  }

  globalThis.getHome = getHome;
  globalThis.search = search;
  globalThis.load = load;
  globalThis.loadStreams = loadStreams;
})();
