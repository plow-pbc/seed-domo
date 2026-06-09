/* Install dashboard SPA — pure vanilla JS, no framework, no build step.
 *
 * It is agent- and SEED-agnostic: it renders whatever the *state object* (see
 * ref/installer/README.md) holds and hardcodes nothing about any particular
 * SEED, agent, connector, or service. The driver supplies all display data over
 * the SSE/HTTP contract; this file only knows the abstract vocabulary of the
 * contract (statuses, where-kinds, field types).
 *
 * Flow:
 *   - read the token the server injected into the page (window.__TOKEN__)
 *   - open an EventSource to /s/<token>/events
 *   - on each `data: <state-json>` message, re-render the whole page
 */

(function () {
  "use strict";

  // ---- token + endpoints -------------------------------------------------
  var TOKEN = (typeof window.__TOKEN__ === "string") ? window.__TOKEN__ : "";
  // If the server didn't substitute the placeholder, treat as empty.
  if (TOKEN === "%TOKEN%") TOKEN = "";
  var BASE = "/s/" + encodeURIComponent(TOKEN);
  var EVENTS_URL = BASE + "/events";

  var contentEl = document.getElementById("content");
  var headerTitleEl = document.getElementById("hd-title");

  // ---- small DOM helpers -------------------------------------------------
  function el(tag, opts, children) {
    var node = document.createElement(tag);
    opts = opts || {};
    if (opts.class) node.className = opts.class;
    if (opts.text != null) node.textContent = String(opts.text);
    // No innerHTML path: all driver-supplied strings go through textContent /
    // createTextNode, so state data can never inject markup (XSS-safe).
    if (opts.attrs) {
      for (var a in opts.attrs) {
        if (opts.attrs.hasOwnProperty(a) && opts.attrs[a] != null) {
          node.setAttribute(a, opts.attrs[a]);
        }
      }
    }
    if (opts.on) {
      for (var ev in opts.on) {
        if (opts.on.hasOwnProperty(ev)) node.addEventListener(ev, opts.on[ev]);
      }
    }
    if (children) {
      if (!Array.isArray(children)) children = [children];
      children.forEach(function (c) {
        if (c == null) return;
        node.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
      });
    }
    return node;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function spinner(size) { return el("div", { class: "spin" + (size ? " " + size : "") }); }

  function copyToClipboard(text, btn, doneLabel) {
    var restore = btn.textContent;
    function ok() {
      btn.textContent = doneLabel || "Copied";
      btn.classList.add("done");
      setTimeout(function () { btn.textContent = restore; btn.classList.remove("done"); }, 1600);
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(ok, function () { fallbackCopy(text); ok(); });
      } else {
        fallbackCopy(text); ok();
      }
    } catch (e) {
      fallbackCopy(text); ok();
    }
  }
  function fallbackCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "absolute";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand("copy"); } catch (e) { /* ignore */ }
    document.body.removeChild(ta);
  }

  // ---- renderers ---------------------------------------------------------

  function render(state) {
    state = state || {};
    headerTitleEl.textContent = (state.title || "Setup");
    if (state.title) document.title = state.title;

    clear(contentEl);

    // Success state takes over the whole body.
    if (state.done) {
      renderDone(state);
      return;
    }

    if (state.kicker) contentEl.appendChild(el("p", { class: "kicker", text: state.kicker }));
    if (state.title) contentEl.appendChild(el("h1", { class: "h1", text: state.title }));
    if (state.subtitle) contentEl.appendChild(el("p", { class: "sub", text: state.subtitle }));
    if (state.message) contentEl.appendChild(el("div", { class: "banner", text: state.message }));

    if (Array.isArray(state.steps) && state.steps.length) {
      contentEl.appendChild(renderSteps(state.steps));
    }
    if (state.verification && Array.isArray(state.verification) && state.verification.length) {
      contentEl.appendChild(renderVerification(state.verification));
    }
  }

  function renderDone(state) {
    var wrap = el("div", { class: "done-wrap" });
    wrap.appendChild(el("div", { class: "done-badge", text: "✓" }));
    if (state.kicker) wrap.appendChild(el("p", { class: "kicker", text: state.kicker }));
    wrap.appendChild(el("h1", { class: "h1", text: state.title || "All set" }));
    if (state.subtitle) wrap.appendChild(el("p", { class: "sub", text: state.subtitle }));
    if (state.message) wrap.appendChild(el("p", { class: "sub", text: state.message }));
    contentEl.appendChild(wrap);
  }

  function renderSteps(steps) {
    var box = el("div", { class: "steps" });
    steps.forEach(function (step, i) {
      var status = step.status || "pending";
      var rowClass = "row" + (i === 0 ? " first" : "") + (status === "pending" ? " pend" : "");

      // Waiting steps with an action expand into a card; render the icon + card
      // together inside the row.
      var isActionCard = (status === "waiting" || status === "active") && step.action;

      var row = el("div", { class: rowClass });
      row.appendChild(stepIcon(status, i));

      var col = el("div", { class: "col" });
      if (isActionCard) {
        col.appendChild(renderActionCard(step));
      } else {
        col.appendChild(el("div", { class: "lab", text: step.label || "" }));
        if (step.detail) {
          col.appendChild(el("div", {
            class: "meta" + (status === "error" ? " err" : ""),
            text: step.detail
          }));
        }
      }
      row.appendChild(col);
      box.appendChild(row);
    });
    return box;
  }

  function stepIcon(status, index) {
    if (status === "ok") return el("div", { class: "dot done", text: "✓" });
    if (status === "error") return el("div", { class: "dot err", text: "✗" });
    if (status === "active" || status === "waiting") {
      var bare = el("div", { class: "dot bare" });
      bare.appendChild(spinner());
      return bare;
    }
    // pending -> muted number (1-based)
    return el("div", { class: "dot pend", text: String(index + 1) });
  }

  function renderActionCard(step) {
    var action = step.action || {};
    var card = el("div", { class: "active" });

    var whereLabel = whereText(action.where);
    card.appendChild(el("span", { class: "where", text: "↳ " + whereLabel }));
    card.appendChild(el("div", { class: "step-h", text: step.label || "" }));

    if (action.command) {
      card.appendChild(commandBox(action.command));
    }
    if (action.link) {
      card.appendChild(linkButton(action.link, action.where));
    }
    if (action.instruction) {
      card.appendChild(el("div", { class: "then", text: action.instruction }));
    }
    if (step.detail) {
      card.appendChild(el("div", { class: "then", text: step.detail }));
    }

    // Live "watching" affordance — detection is automatic; this just reassures.
    var watch = el("div", { class: "watch" });
    watch.appendChild(spinner("sm"));
    watch.appendChild(document.createTextNode(
      step.status === "active"
        ? "Working — this checks off on its own."
        : "Watching — this checks off the instant it's done."
    ));
    card.appendChild(watch);

    return card;
  }

  function whereText(where) {
    switch (where) {
      case "terminal": return "run this in your terminal";
      case "browser":  return "do this in your browser";
      case "phone":    return "do this on your phone";
      default:         return "do this";
    }
  }

  function commandBox(command) {
    var box = el("div", { class: "cmd" });
    var code = el("code");
    code.appendChild(el("span", { class: "pr", text: "$" }));
    code.appendChild(document.createTextNode(command));
    box.appendChild(code);

    var btn = el("button", { class: "copy", attrs: { type: "button" }, text: "⧉ Copy" });
    btn.addEventListener("click", function () { copyToClipboard(command, btn, "✓ Copied"); });
    box.appendChild(btn);
    return box;
  }

  function linkButton(href, where) {
    // Only allow http(s) links to be navigable; otherwise show as plain text.
    var safe = /^https?:\/\//i.test(href);
    if (!safe) {
      return el("div", { class: "then", text: href });
    }
    var a = el("a", {
      class: "linkbtn",
      attrs: { href: href, target: "_blank", rel: "noopener noreferrer" }
    });
    a.appendChild(el("span", { text: linkLabel(href) }));
    a.appendChild(el("span", { class: "arr", text: "↗" }));
    return a;
  }

  function linkLabel(href) {
    try {
      var u = new URL(href);
      return "Open " + u.hostname.replace(/^www\./, "");
    } catch (e) {
      return "Open link";
    }
  }

  // ---- verification ------------------------------------------------------

  function renderVerification(members) {
    var box = el("div", { class: "verify" });
    var total = members.length;
    var verified = members.filter(function (m) { return m.status === "verified"; }).length;

    members.forEach(function (m) {
      box.appendChild(renderMember(m));
    });

    // progress bar
    var bar = el("div", { class: "bar" });
    var fill = el("span");
    fill.style.width = total ? Math.round((verified / total) * 100) + "%" : "0%";
    bar.appendChild(fill);
    box.appendChild(bar);

    var foot = el("div", { class: "foot" });
    if (verified < total) {
      foot.appendChild(spinner("sm"));
      var pending = members.filter(function (m) { return m.status !== "verified"; })
        .map(function (m) { return m.name; });
      var tail = pending.length === 1
        ? " — waiting on " + pending[0] + "…"
        : " — waiting on " + pending.length + " more…";
      foot.appendChild(document.createTextNode(verified + " of " + total + " verified" + tail));
    } else {
      foot.appendChild(el("div", { class: "check", text: "✓" }));
      foot.appendChild(document.createTextNode("All " + total + " verified."));
    }
    box.appendChild(foot);

    return box;
  }

  function renderMember(m) {
    var status = m.status || "pending";
    var rowClass = "mrow" + (status === "verified" ? " ok" : status === "error" ? " err" : "");
    var row = el("div", { class: rowClass });

    var initial = (m.name || "?").trim().charAt(0) || "?";
    row.appendChild(el("div", { class: "av", text: initial }));

    var who = el("div", { class: "who" });
    var nm = el("div", { class: "nm" });
    nm.appendChild(document.createTextNode(m.name || ""));
    if (m.isSelf) nm.appendChild(el("span", { class: "you", text: " · you" }));
    who.appendChild(nm);

    var instText;
    if (status === "verified") {
      instText = "verified";
    } else if (status === "error") {
      instText = "couldn't verify — resend the code";
    } else if (m.isSelf) {
      // Solo / the owner: YOU still have to text the code. Show how.
      instText = m.number ? ("Text this from your phone to " + m.number) : "Text this from your phone";
    } else if (m.number) {
      instText = "Send " + (m.name || "them") + " this code — they text it to " + m.number;
    } else {
      instText = "Send " + (m.name || "them") + " this code to text in";
    }
    who.appendChild(el("div", { class: "inst", text: instText }));
    row.appendChild(who);

    // Any pending/error member with a code shows the chip + Copy (incl. you).
    if (status !== "verified" && m.code) {
      var codeWrap = el("div", { class: "code" });
      codeWrap.appendChild(el("span", { class: "chip", text: m.code }));
      var cp = el("button", { class: "cp", attrs: { type: "button" }, text: "⧉ Copy" });
      cp.addEventListener("click", function () { copyToClipboard(m.code, cp, "✓"); });
      codeWrap.appendChild(cp);
      row.appendChild(codeWrap);
    }

    if (status !== "verified" && m.number) {
      var numberWrap = el("div", { class: "number" });
      numberWrap.appendChild(el("span", { class: "number-label", text: "to" }));
      numberWrap.appendChild(el("span", { class: "phone", text: m.number }));
      var ncp = el("button", { class: "cp number-copy", attrs: { type: "button" }, text: "⧉ Copy" });
      ncp.addEventListener("click", function () { copyToClipboard(m.number, ncp, "✓"); });
      numberWrap.appendChild(ncp);
      row.appendChild(numberWrap);
    }

    // status indicator
    var st;
    if (status === "verified") {
      st = el("div", { class: "vstatus ok" });
      st.appendChild(el("div", { class: "check", text: "✓" }));
      st.appendChild(document.createTextNode("Verified"));
    } else if (status === "error") {
      st = el("div", { class: "vstatus err" });
      st.appendChild(el("div", { class: "check err", text: "✗" }));
      st.appendChild(document.createTextNode("Failed"));
    } else {
      st = el("div", { class: "vstatus wait" });
      st.appendChild(spinner("md"));
    }
    row.appendChild(st);

    return row;
  }

  // ---- live connection ---------------------------------------------------

  var lastState = null;
  function renderCurrent() { if (lastState) render(lastState); }

  function showDisconnected() {
    var note = document.querySelector(".disconnected");
    if (note) return;
    note = el("div", { class: "disconnected" });
    note.appendChild(spinner("sm"));
    note.appendChild(document.createTextNode("Reconnecting…"));
    contentEl.appendChild(note);
  }
  function clearDisconnected() {
    var note = document.querySelector(".disconnected");
    if (note && note.parentNode) note.parentNode.removeChild(note);
  }

  function connect() {
    if (!TOKEN) {
      clear(contentEl);
      contentEl.appendChild(el("p", { class: "connecting", text: "Missing setup token — reopen the link from your terminal." }));
      return;
    }
    var es = new EventSource(EVENTS_URL);

    es.onmessage = function (e) {
      clearDisconnected();
      var state;
      try { state = JSON.parse(e.data); }
      catch (err) { return; }
      lastState = state;
      render(state);
      if (state && state.done) {
        // Install finished; the driver will tear down the server. Stop listening.
        es.close();
      }
    };

    es.onerror = function () {
      // EventSource auto-reconnects; surface a subtle note meanwhile.
      showDisconnected();
    };
  }

  connect();
})();
