/* 桃花源捕获层页内脚本（document-start，全帧注册）。
 * 三路并行：XHR/fetch 请求记录、video 监听、Blob/MSE 推断。
 * 所有上报走 window.Android 回调（onRequest/onMedia/onBlob/onMse），
 * 原生侧收不到回调时不抛错、不影响页面。
 * 注意：本脚本不读、不改页面业务逻辑，只记录网络与媒体事件。
 */
(function () {
  if (window.__thCaptureInstalled) return;
  window.__thCaptureInstalled = true;

  var MAX = 2048;
  var seen = Object.create(null);

  function callNative(name, args) {
    try {
      if (window.Android && typeof window.Android[name] === "function") {
        window.Android[name].apply(window.Android, args);
      }
    } catch (e) {}
  }

  function report(url, type, body) {
    try {
      if (!url) return;
      var u = String(url);
      var key = String(type) + "|" + u;
      if (seen[key]) return;
      seen[key] = 1;
      var s = body == null ? "" : String(body).slice(0, MAX);
      callNative("onRequest", [u, String(type || ""), s]);
    } catch (e) {}
  }

  function abs(u) {
    try { return new URL(String(u), location.href).href; } catch (e) { return String(u); }
  }

  function isText(ct) {
    if (!ct) return true;
    return /text\/|json|xml|javascript|ecmascript|urlencoded|svg|csv|html/i.test(ct);
  }

  /* ---- XHR ---- */
  var XO = XMLHttpRequest.prototype.open;
  var XS = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function (method, url) {
    try {
      this.__hu = abs(url);
      this.__hm = String(method || "GET").toUpperCase();
    } catch (e) {}
    return XO.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    try {
      xhr.addEventListener("load", function () {
        var url = xhr.__hu || "";
        var type = xhr.__hm || "GET";
        var text = null;
        try {
          var ct = "";
          try { ct = xhr.getResponseHeader("content-type") || ""; } catch (e) {}
          if (isText(ct)) {
            var rt = xhr.responseType;
            if (rt === "" || rt === "text") text = xhr.responseText;
            else if (rt === "json") text = JSON.stringify(xhr.response);
          }
        } catch (e) { text = null; }
        report(url, type, text);
      });
      xhr.addEventListener("error", function () { report(xhr.__hu, xhr.__hm, ""); });
      xhr.addEventListener("timeout", function () { report(xhr.__hu, xhr.__hm, ""); });
    } catch (e) {}
    return XS.apply(this, arguments);
  };

  /* ---- fetch ---- */
  var WF = window.fetch;
  if (typeof WF === "function") {
    window.fetch = function (input, init) {
      var url = "";
      var method = "GET";
      try {
        url = abs(typeof input === "string" ? input : (input && input.url) || "");
        method = String((init && init.method) || (input && input.method) || "GET").toUpperCase();
      } catch (e) {}
      var p = WF.apply(this, arguments);
      try {
        p.then(function (res) {
          var target = res.url || url;
          try {
            var ct = res.headers.get("content-type") || "";
            if (!isText(ct)) { report(target, method, ""); return; }
            res.clone().text().then(function (t) {
              report(target, method, t);
            }).catch(function () { report(target, method, ""); });
          } catch (e) {
            report(target, method, "");
          }
        }).catch(function () { report(url, method, ""); });
      } catch (e) {}
      return p;
    };
  }

  /* ---- Blob：createObjectURL / revokeObjectURL ---- */
  try {
    var origCreate = URL.createObjectURL;
    if (typeof origCreate === "function") {
      URL.createObjectURL = function (obj) {
        var url = origCreate.apply(this, arguments);
        try {
          var kind = obj ? (obj.constructor ? obj.constructor.name : typeof obj) : "";
          callNative("onBlob", [String(url), String(kind)]);
        } catch (e) {}
        return url;
      };
    }
    var origRevoke = URL.revokeObjectURL;
    if (typeof origRevoke === "function") {
      URL.revokeObjectURL = function (url) {
        try { callNative("onBlobRevoked", [String(url)]); } catch (e) {}
        return origRevoke.apply(this, arguments);
      };
    }
  } catch (e) {}

  /* ---- MSE：MediaSource + SourceBuffer.appendBuffer ---- */
  try {
    if (typeof MediaSource !== "undefined" && MediaSource.prototype.addSourceBuffer) {
      var origAddSB = MediaSource.prototype.addSourceBuffer;
      MediaSource.prototype.addSourceBuffer = function (mime) {
        var sb = origAddSB.apply(this, arguments);
        try {
          var origAppend = sb.appendBuffer;
          sb.appendBuffer = function (data) {
            try {
              var size = data ? data.byteLength || data.length || 0 : 0;
              callNative("onMseAppend", [String(mime || ""), String(size)]);
            } catch (e) {}
            return origAppend.apply(this, arguments);
          };
          callNative("onMse", [String(mime || "")]);
        } catch (e) {}
        return sb;
      };
    }
  } catch (e) {}

  /* ---- video 监听 ---- */
  function watchVideo(v) {
    try {
      if (!v || v.__hooked) return;
      v.__hooked = true;
      var last = "";
      var fire = function () {
        var src = v.currentSrc || v.src || v.getAttribute("src") || "";
        if (src && src !== last) {
          last = src;
          callNative("onMedia", [abs(src), "video", String(v.duration || 0), String(!v.paused)]);
        }
      };
      fire();
      v.addEventListener("loadstart", fire, true);
      v.addEventListener("loadedmetadata", fire, true);
      v.addEventListener("playing", fire, true);
      try {
        new MutationObserver(fire).observe(v, { attributes: true, attributeFilter: ["src"] });
      } catch (e) {}
      var sources = v.querySelectorAll("source");
      for (var i = 0; i < sources.length; i++) {
        (function (so) {
          var f = function () { if (so.src) callNative("onMedia", [abs(so.src), "source", "0", "false"]); };
          f();
          so.addEventListener("error", f);
        })(sources[i]);
      }
    } catch (e) {}
  }

  function scan(root) {
    try {
      if (!root || !root.querySelectorAll) return;
      var vs = root.querySelectorAll("video");
      for (var i = 0; i < vs.length; i++) watchVideo(vs[i]);
    } catch (e) {}
  }

  try {
    new MutationObserver(function (muts) {
      for (var i = 0; i < muts.length; i++) {
        var m = muts[i];
        if (m.type === "attributes" && m.target && m.target.tagName === "VIDEO") {
          watchVideo(m.target);
        }
        var added = m.addedNodes || [];
        for (var j = 0; j < added.length; j++) {
          var n = added[j];
          if (!n || n.nodeType !== 1) continue;
          if (n.tagName === "VIDEO") watchVideo(n);
          scan(n);
        }
      }
    }).observe(document.documentElement || document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["src"]
    });
  } catch (e) {}

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { scan(document); });
  } else {
    scan(document);
  }

  /* ---- performance 资源快照：原生侧按需调 window.__thResources() 拿 ---- */
  window.__thResources = function () {
    try {
      var entries = performance.getEntriesByType("resource") || [];
      var out = [];
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (e && e.name) out.push(e.name);
      }
      return out;
    } catch (err) {
      return [];
    }
  };

  /* ---- frame 树快照：原生侧按需调 window.__thFrames() 拿 ---- */
  window.__thFrames = function () {
    function walk(w, depth) {
      var n = 0;
      var u = "cross-origin";
      try { n = w.frames.length; } catch (e) {}
      try { u = w.location.href; } catch (e) {}
      var node = { url: u, depth: depth, children: n, frames: [] };
      for (var i = 0; i < n; i++) {
        try { node.frames.push(walk(w.frames[i], depth + 1)); } catch (e) {}
      }
      return node;
    }
    try {
      return walk(window, 0);
    } catch (err) {
      return {};
    }
  };
})();
