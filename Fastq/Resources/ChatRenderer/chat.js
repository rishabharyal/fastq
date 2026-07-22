/* Chat message renderer.
 *
 * Pipeline (window.updateMessage):
 *   1. stabilize()    — while streaming, auto-close dangling code fences and
 *                       hold back a trailing unterminated $$ block so partial
 *                       markdown never breaks the page.
 *   2. extractMath()  — pull TeX out into slots BEFORE markdown runs, so
 *                       underscores/asterisks inside math are never mangled.
 *                       Fenced code and inline code spans are protected first.
 *   3. marked.parse() — GFM markdown (tables, task lists, strikethrough…).
 *                       Raw HTML in the model output is escaped, code blocks
 *                       get a header + copy button + highlight.js colors.
 *   4. buffer render  — KaTeX renders into a detached buffer, tables get
 *                       scroll wrappers, then the buffer is diffed against
 *                       the live DOM block-by-block: only changed top-level
 *                       blocks are swapped, so earlier content never flickers
 *                       while tokens stream in.
 *   5. height post    — a ResizeObserver reports content height to Swift.
 */
"use strict";
(function () {
  var out = document.getElementById("out");
  var caret = document.getElementById("caret");

  var SLOT_OPEN = "";
  var SLOT_CLOSE = "";
  var mathSlots = [];

  // ---- helpers -----------------------------------------------------------

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function b64encode(s) {
    var bytes = new TextEncoder().encode(s);
    var bin = "";
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin);
  }

  function b64decode(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder("utf-8").decode(bytes);
  }

  function postHeight() {
    try {
      var h = Math.ceil(out.getBoundingClientRect().height);
      if (!caret.hidden) h += 20;
      window.webkit.messageHandlers.height.postMessage(Math.max(h, 4));
    } catch (_) {}
  }

  // ---- streaming stabilization --------------------------------------------

  function stabilize(src, streaming) {
    if (!streaming) return src;
    // Auto-close a dangling fenced code block so partial code renders live.
    var fences = (src.match(/```/g) || []).length;
    if (fences % 2 === 1) src += "\n```";
    // Hold back a trailing unterminated display-math block; it renders whole
    // once the closing delimiter arrives (no half-parsed TeX flashes).
    var dd = (src.match(/\$\$/g) || []).length;
    if (dd % 2 === 1) {
      var cut = src.lastIndexOf("$$");
      if (cut >= 0) src = src.slice(0, cut);
    }
    var openBracket = src.lastIndexOf("\\[");
    if (openBracket >= 0 && src.indexOf("\\]", openBracket) < 0) {
      src = src.slice(0, openBracket);
    }
    return src;
  }

  // ---- math extraction -----------------------------------------------------

  function stashMath(tex, display) {
    var id = mathSlots.length;
    mathSlots.push({ tex: tex.trim(), display: !!display });
    return SLOT_OPEN + "MATH" + id + SLOT_CLOSE;
  }

  function mathInPlainText(s) {
    s = s.replace(/\$\$([\s\S]+?)\$\$/g, function (_, tex) { return stashMath(tex, true); });
    s = s.replace(/\\\[([\s\S]+?)\\\]/g, function (_, tex) { return stashMath(tex, true); });
    s = s.replace(/\\\(([\s\S]+?)\\\)/g, function (_, tex) { return stashMath(tex, false); });
    // Inline $...$ — skip escaped \$, $$ and currency like "$5" / "$5.40".
    s = s.replace(/(^|[^\\$])\$([^$\n]+?)\$(?!\$)/g, function (m, pre, tex) {
      if (/^\s*\d/.test(tex) && !/[\\^_{}=]/.test(tex)) return m;
      return pre + stashMath(tex, false);
    });
    return s;
  }

  function extractMath(src) {
    mathSlots = [];
    // Protect fenced code blocks, then inline code spans, from math regexes.
    var fenceParts = src.split(/(```[\s\S]*?(?:```|$))/);
    return fenceParts.map(function (part) {
      if (part.lastIndexOf("```", 0) === 0) return part;
      var codeParts = part.split(/(`[^`\n]*`)/);
      return codeParts.map(function (seg) {
        if (seg.length > 1 && seg.charAt(0) === "`" && seg.charAt(seg.length - 1) === "`") return seg;
        return mathInPlainText(seg);
      }).join("");
    }).join("");
  }

  function injectMathPlaceholders(html) {
    var re = new RegExp(SLOT_OPEN + "MATH(\\d+)" + SLOT_CLOSE, "g");
    return html.replace(re, function (_, idStr) {
      var slot = mathSlots[parseInt(idStr, 10)];
      if (!slot) return "";
      var cls = slot.display ? "math math-display" : "math math-inline";
      return '<span class="' + cls + '" data-mid="' + idStr + '"></span>';
    });
  }

  function renderMathIn(root) {
    root.querySelectorAll(".math").forEach(function (el) {
      var slot = mathSlots[parseInt(el.getAttribute("data-mid"), 10)];
      if (!slot) return;
      try {
        katex.render(slot.tex, el, {
          throwOnError: false,
          displayMode: slot.display,
          strict: "ignore",
          trust: false,
          macros: {
            "\\R": "\\mathbb{R}",
            "\\N": "\\mathbb{N}",
            "\\Z": "\\mathbb{Z}",
            "\\Q": "\\mathbb{Q}",
            "\\C": "\\mathbb{C}"
          }
        });
      } catch (err) {
        el.className = "math-error";
        el.textContent = slot.tex;
      }
    });
  }

  // ---- markdown ------------------------------------------------------------

  function tokenText(arg, key) {
    // marked v12 passes strings; be tolerant of token objects too.
    if (typeof arg === "string") return arg;
    if (arg && typeof arg === "object") return String(arg[key || "text"] || "");
    return "";
  }

  function renderCodeBlock(code, infostring) {
    var raw = tokenText(code, "text");
    var lang = tokenText(infostring, "lang").trim().split(/\s+/)[0].toLowerCase();
    var body;
    if (lang && typeof hljs !== "undefined" && hljs.getLanguage(lang)) {
      try {
        body = hljs.highlight(raw, { language: lang, ignoreIllegals: true }).value;
      } catch (_) {
        body = escapeHtml(raw);
      }
    } else {
      body = escapeHtml(raw);
    }
    return '<div class="codeblock" data-code="' + b64encode(raw) + '">'
      + '<div class="codeblock-head">'
      + '<span class="codeblock-lang">' + escapeHtml(lang || "code") + '</span>'
      + '<button class="copy-btn" type="button">Copy</button>'
      + '</div>'
      + '<pre><code class="hljs">' + body + '</code></pre>'
      + '</div>';
  }

  marked.use({
    gfm: true,
    breaks: true,
    renderer: {
      code: function (code, infostring) { return renderCodeBlock(code, infostring); },
      // Never let model-authored raw HTML into the DOM.
      html: function (html) { return escapeHtml(tokenText(html)); }
    }
  });

  // ---- DOM diff patch --------------------------------------------------------

  function patchInto(container, buffer) {
    var oldNodes = Array.prototype.slice.call(container.children);
    var newNodes = Array.prototype.slice.call(buffer.children);
    var shared = Math.min(oldNodes.length, newNodes.length);
    for (var i = 0; i < shared; i++) {
      if (oldNodes[i].outerHTML !== newNodes[i].outerHTML) {
        container.replaceChild(newNodes[i], oldNodes[i]);
      }
    }
    for (var j = oldNodes.length - 1; j >= shared; j--) {
      container.removeChild(oldNodes[j]);
    }
    for (var k = shared; k < newNodes.length; k++) {
      container.appendChild(newNodes[k]);
    }
  }

  // ---- entry point -----------------------------------------------------------

  window.updateMessage = function (b64, streaming, isError) {
    var src = b64decode(b64);
    src = stabilize(src, !!streaming);
    src = extractMath(src);

    var html;
    try {
      html = marked.parse(src);
    } catch (_) {
      html = "<p>" + escapeHtml(src) + "</p>";
    }
    html = injectMathPlaceholders(html);

    var buffer = document.createElement("div");
    buffer.innerHTML = html;
    renderMathIn(buffer);
    buffer.querySelectorAll("table").forEach(function (table) {
      var wrap = document.createElement("div");
      wrap.className = "table-wrap";
      table.parentNode.insertBefore(wrap, table);
      wrap.appendChild(table);
    });

    out.className = isError ? "error-tone" : "";
    patchInto(out, buffer);
    caret.hidden = !streaming;

    postHeight();
    requestAnimationFrame(postHeight);
  };

  // ---- interactions -----------------------------------------------------------

  document.addEventListener("click", function (event) {
    var btn = event.target.closest(".copy-btn");
    if (!btn) return;
    var block = btn.closest(".codeblock");
    if (!block) return;
    try {
      window.webkit.messageHandlers.copyCode.postMessage(b64decode(block.getAttribute("data-code")));
    } catch (_) {}
    btn.textContent = "Copied";
    btn.classList.add("done");
    setTimeout(function () {
      btn.textContent = "Copy";
      btn.classList.remove("done");
    }, 1300);
  });

  // Fonts (KaTeX) finishing load can change layout after first render.
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(function () { postHeight(); });
  }

  new ResizeObserver(function () { postHeight(); }).observe(out);

  try { window.webkit.messageHandlers.height.postMessage(1); } catch (_) {}
})();
