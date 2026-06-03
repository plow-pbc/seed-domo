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
 *   - forms POST JSON back to /s/<token>/answers
 */

(function () {
  "use strict";

  // ---- token + endpoints -------------------------------------------------
  var TOKEN = (typeof window.__TOKEN__ === "string") ? window.__TOKEN__ : "";
  // If the server didn't substitute the placeholder, treat as empty.
  if (TOKEN === "%TOKEN%") TOKEN = "";
  var BASE = "/s/" + encodeURIComponent(TOKEN);
  var EVENTS_URL = BASE + "/events";
  var ANSWERS_URL = BASE + "/answers";

  var contentEl = document.getElementById("content");
  var headerTitleEl = document.getElementById("hd-title");

  // Holds in-progress form edits keyed by field id, so a re-render driven by a
  // status flip elsewhere doesn't wipe what the user is typing. Reset when a
  // fresh (unsubmitted) form arrives the first time or after submit.
  var formDraft = null;       // { fieldId: value }
  var formDraftKey = null;    // signature of the form we're drafting against
  var submitting = false;

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
    if (state.form) {
      contentEl.appendChild(renderForm(state.form));
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

  // ---- form --------------------------------------------------------------

  function formSignature(form) {
    // Identify "the same form" so drafts persist across unrelated re-renders.
    var ids = (form.fields || []).map(function (f) { return f.id + ":" + f.type; });
    return (form.title || "") + "|" + ids.join(",");
  }

  function ensureDraft(form) {
    var sig = formSignature(form);
    if (formDraftKey !== sig) {
      // New form: seed the draft from supplied values.
      formDraft = {};
      formDraftKey = sig;
      (form.fields || []).forEach(function (f) {
        if (f.type === "list") {
          formDraft[f.id] = Array.isArray(f.value) ? f.value.slice() : [];
        } else if (f.type === "choice") {
          formDraft[f.id] = (f.value != null) ? f.value : null;
        } else {
          formDraft[f.id] = (f.value != null) ? f.value : "";
        }
      });
    }
    return formDraft;
  }

  function renderForm(form) {
    var draft = ensureDraft(form);
    var wrap = el("div", { class: "form" });

    if (form.title) wrap.appendChild(el("div", { class: "form-title", text: form.title }));
    if (form.intro) wrap.appendChild(el("div", { class: "form-intro", text: form.intro }));

    var fields = Array.isArray(form.fields) ? form.fields : [];

    if (form.submitted) {
      // Already submitted: show fields read-only-ish is overkill; show a note.
      fields.forEach(function (f) { wrap.appendChild(renderField(f, draft, true)); });
      var note = el("div", { class: "submitted-note" });
      note.appendChild(el("div", { class: "check", text: "✓" }));
      note.appendChild(document.createTextNode("Submitted — thanks."));
      wrap.appendChild(note);
      return wrap;
    }

    fields.forEach(function (f) { wrap.appendChild(renderField(f, draft, false)); });

    var submit = el("button", {
      class: "submit",
      attrs: { type: "button" },
      text: submitting ? "Submitting…" : "Submit"
    });
    if (submitting) submit.disabled = true;
    submit.addEventListener("click", function () { submitForm(form); });
    wrap.appendChild(submit);

    return wrap;
  }

  function renderField(field, draft, disabled) {
    var wrap = el("div", { class: "field" });
    var labelChildren = [field.label || field.id || ""];
    if (field.required) labelChildren.push(el("span", { class: "req", text: "*" }));
    wrap.appendChild(el("label", { class: "fl" }, labelChildren));

    var type = field.type || "text";
    if (type === "choice") {
      wrap.appendChild(renderChoice(field, draft, disabled));
    } else if (type === "list") {
      wrap.appendChild(renderList(field, draft, disabled));
    } else if (type === "multiline") {
      var ta = el("textarea", {
        class: "multiline-input",
        attrs: { placeholder: field.placeholder || "" }
      });
      ta.value = draft[field.id] != null ? draft[field.id] : "";
      if (disabled) ta.disabled = true;
      ta.addEventListener("input", function () { draft[field.id] = ta.value; });
      wrap.appendChild(ta);
    } else {
      // text (default)
      var input = el("input", {
        class: "text-input",
        attrs: { type: "text", placeholder: field.placeholder || "" }
      });
      input.value = draft[field.id] != null ? draft[field.id] : "";
      if (disabled) input.disabled = true;
      input.addEventListener("input", function () { draft[field.id] = input.value; });
      wrap.appendChild(input);
    }
    return wrap;
  }

  function renderChoice(field, draft, disabled) {
    var box = el("div", { class: "choices" });
    var options = Array.isArray(field.options) ? field.options : [];
    options.forEach(function (opt) {
      var selected = draft[field.id] === opt;
      var c = el("div", { class: "choice" + (selected ? " sel" : "") });
      c.appendChild(el("div", { class: "radio" }));
      c.appendChild(el("span", { text: String(opt) }));
      if (!disabled) {
        c.addEventListener("click", function () {
          draft[field.id] = opt;
          // re-render just the choices group
          var parent = box.parentNode;
          var fresh = renderChoice(field, draft, disabled);
          parent.replaceChild(fresh, box);
        });
      }
      box.appendChild(c);
    });
    return box;
  }

  function renderList(field, draft, disabled) {
    var box = el("div", {});
    var rowsWrap = el("div", { class: "list-rows" });
    var values = Array.isArray(draft[field.id]) ? draft[field.id] : (draft[field.id] = []);

    function redraw() {
      var fresh = renderList(field, draft, disabled);
      box.parentNode.replaceChild(fresh, box);
    }

    if (values.length === 0) values.push("");

    values.forEach(function (val, idx) {
      var row = el("div", { class: "list-row" });
      var input = el("input", {
        class: "text-input",
        attrs: { type: "text", placeholder: field.placeholder || "" }
      });
      input.value = val != null ? val : "";
      if (disabled) input.disabled = true;
      input.addEventListener("input", function () { values[idx] = input.value; });
      row.appendChild(input);

      if (!disabled) {
        var rm = el("button", { class: "list-rm", attrs: { type: "button", "aria-label": "Remove" }, text: "×" });
        rm.addEventListener("click", function () {
          values.splice(idx, 1);
          redraw();
        });
        row.appendChild(rm);
      }
      rowsWrap.appendChild(row);
    });
    box.appendChild(rowsWrap);

    if (!disabled) {
      var add = el("button", { class: "list-add", attrs: { type: "button" }, text: "+ Add" });
      add.addEventListener("click", function () {
        values.push("");
        redraw();
      });
      box.appendChild(add);
    }
    return box;
  }

  function submitForm(form) {
    if (submitting) return;
    var draft = ensureDraft(form);

    // Build clean values: trim text, drop empty list entries.
    var values = {};
    (form.fields || []).forEach(function (f) {
      var v = draft[f.id];
      if (f.type === "list") {
        values[f.id] = (Array.isArray(v) ? v : [])
          .map(function (s) { return (s == null ? "" : String(s)).trim(); })
          .filter(function (s) { return s.length > 0; });
      } else if (f.type === "choice") {
        values[f.id] = (v != null) ? v : null;
      } else {
        values[f.id] = (v == null ? "" : String(v)).trim();
      }
    });

    // Minimal required-field check (display data only; the driver re-validates).
    var missing = (form.fields || []).filter(function (f) {
      if (!f.required) return false;
      var val = values[f.id];
      if (f.type === "list") return !val.length;
      if (f.type === "choice") return val == null;
      return !val;
    });
    if (missing.length) {
      // Flash a banner-ish note; keep it simple and non-blocking.
      flashMissing(missing);
      return;
    }

    submitting = true;
    // re-render to disable the button
    renderCurrent();

    fetch(ANSWERS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ values: values })
    }).then(function (res) {
      submitting = false;
      if (!res.ok) {
        flashError("Couldn't submit (" + res.status + "). Try again.");
        renderCurrent();
      }
      // On success the server sets form.submitted=true and broadcasts new state
      // over SSE, which will re-render us. Nothing else to do here.
    }).catch(function () {
      submitting = false;
      flashError("Network error submitting. Try again.");
      renderCurrent();
    });
  }

  function flashMissing(fields) {
    var labels = fields.map(function (f) { return f.label || f.id; }).join(", ");
    flashError("Please fill in: " + labels);
  }

  var flashTimer = null;
  function flashError(msg) {
    var existing = document.querySelector(".form .banner.err-flash");
    if (existing) existing.parentNode.removeChild(existing);
    var formEl = document.querySelector(".form");
    if (!formEl) return;
    var b = el("div", { class: "banner err-flash", text: msg });
    b.style.background = "#f7ecec";
    b.style.borderColor = "#e3cccc";
    b.style.color = "#b04a4a";
    formEl.insertBefore(b, formEl.firstChild);
    if (flashTimer) clearTimeout(flashTimer);
    flashTimer = setTimeout(function () {
      if (b.parentNode) b.parentNode.removeChild(b);
    }, 4000);
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
    if (m.isSelf) {
      instText = "texted from your phone";
    } else if (status === "verified") {
      instText = "verified";
    } else if (status === "error") {
      instText = "couldn't verify — resend their code";
    } else if (m.number) {
      instText = "Send " + (m.name || "them") + " their code — they text it to " + m.number;
    } else {
      instText = "Send " + (m.name || "them") + " their code to text in";
    }
    who.appendChild(el("div", { class: "inst", text: instText }));
    row.appendChild(who);

    // For non-self pending/error members, show the code chip + Copy + (number).
    if (!m.isSelf && status !== "verified" && m.code) {
      var codeWrap = el("div", { class: "code" });
      codeWrap.appendChild(el("span", { class: "chip", text: m.code }));
      var cp = el("button", { class: "cp", attrs: { type: "button" }, text: "⧉ Copy" });
      cp.addEventListener("click", function () { copyToClipboard(m.code, cp, "✓"); });
      codeWrap.appendChild(cp);
      row.appendChild(codeWrap);
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
