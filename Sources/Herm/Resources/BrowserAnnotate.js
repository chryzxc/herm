// Herm annotate mode: hover highlights an element, click opens a comment box,
// submit posts the element + comment to Herm. Runs in an isolated world (WebKit
// content world / CDP isolated world), so page scripts can't call it or post
// through its channel. `finder` (@medv/finder) is prepended by Herm.
(() => {
  if (window.__hermAnnotate) return;
  const post = (msg) => {
    const s = JSON.stringify(msg);
    if (window.webkit?.messageHandlers?.hermAnnotate) window.webkit.messageHandlers.hermAnnotate.postMessage(s);
    else if (typeof window.hermAnnotate === 'function') window.hermAnnotate(s);
  };
  let enabled = false, picked = null, host = null, ui = null;

  function mount() {
    if (host) return;
    host = document.createElement('div');
    host.style.cssText = 'all:initial;position:fixed;inset:0;pointer-events:none;z-index:2147483647';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>
      :host{--accent:#4f8cff;--on-accent:#fff;--surface:#1d1f23;--field:#111316;--text:#eee;--muted:#9a9ea6;--border:#3a3d44}
      *{box-sizing:border-box}
      .box{position:fixed;border:1.5px solid var(--accent);background:color-mix(in srgb,var(--accent) 10%,transparent);border-radius:4px;display:none;transition:all .08s ease-out}
      .tag{position:fixed;font:600 11px/16px -apple-system,system-ui,sans-serif;color:var(--on-accent);background:var(--accent);padding:1px 6px;border-radius:5px;display:none;white-space:nowrap;max-width:60vw;overflow:hidden;text-overflow:ellipsis}
      .note{position:fixed;width:min(320px,calc(100vw - 16px));pointer-events:auto;background:var(--surface);color:var(--text);border:1px solid var(--border);border-radius:12px;padding:10px;
        box-shadow:0 10px 30px rgba(0,0,0,.28),0 1px 3px rgba(0,0,0,.18);font:13px/1.4 -apple-system,system-ui,sans-serif;animation:in .12s ease-out}
      @keyframes in{from{opacity:0;transform:translateY(-4px)}}
      @media (prefers-reduced-motion:reduce){.note,.box{animation:none;transition:none}}
      .note[hidden]{display:none}
      .el{display:inline-block;max-width:100%;font:500 11px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted);background:var(--field);border:1px solid var(--border);border-radius:5px;padding:1px 6px;margin-bottom:8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      textarea{display:block;width:100%;min-height:38px;max-height:160px;resize:none;background:var(--field);color:inherit;border:1px solid var(--border);border-radius:8px;padding:7px 9px;font:inherit;outline:none}
      textarea:focus{border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}
      textarea::placeholder{color:var(--muted)}
      .row{display:flex;align-items:center;gap:6px;margin-top:8px}
      .hint{flex:1;min-width:0;font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      kbd{font:inherit;padding:0 4px;border:1px solid var(--border);border-radius:4px}
      button{font:500 12px -apple-system,system-ui,sans-serif;border:0;border-radius:7px;padding:5px 11px;cursor:pointer;background:transparent;color:var(--muted)}
      button:hover{color:var(--text);background:var(--field)}
      button[type=submit]{background:var(--accent);color:var(--on-accent)}
      button[type=submit]:hover{filter:brightness(1.08);background:var(--accent);color:var(--on-accent)}
    </style><div class="box"></div><div class="tag"></div>
    <form class="note" hidden><div class="el"></div><textarea rows="1" placeholder="Describe the change…"></textarea>
    <div class="row"><span class="hint"><kbd>↵</kbd> send · <kbd>⇧↵</kbd> newline · <kbd>esc</kbd></span>
    <button type="button" class="cancel">Cancel</button><button type="submit">Send</button></div></form>`;
    ui = { box: root.querySelector('.box'), tag: root.querySelector('.tag'), note: root.querySelector('.note'), el: root.querySelector('.el') };
    ui.text = ui.note.querySelector('textarea');
    ui.note.addEventListener('submit', (e) => { e.preventDefault(); submit(ui.text.value); });
    ui.note.querySelector('.cancel').addEventListener('click', reset);
    ui.text.addEventListener('input', grow);
    ui.text.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); submit(ui.text.value); }
      if (e.key === 'Escape') { e.preventDefault(); reset(); }
      e.stopPropagation();
    });
    document.documentElement.appendChild(host);
  }

  function label(el) {
    const cls = [...el.classList].slice(0, 2).map((c) => '.' + c).join('');
    return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + cls;
  }

  function highlight(el) {
    const r = el.getBoundingClientRect();
    Object.assign(ui.box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
    ui.tag.textContent = `${label(el)}  ${Math.round(r.width)}×${Math.round(r.height)}`;
    Object.assign(ui.tag.style, { display: 'block', left: Math.max(0, r.left) + 'px', top: Math.max(0, r.top - 22) + 'px' });
  }

  const inside = (e) => host && e.composedPath().includes(host);
  const target = (e) => { const el = e.composedPath()[0]; return el instanceof Element ? el : null; };

  function onMove(e) {
    if (!enabled || picked || inside(e)) return;
    const el = target(e);
    if (el) highlight(el);
  }

  function onBlock(e) {
    if (!enabled || inside(e)) return;
    e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
    if (e.type !== 'click') return;
    if (picked) return reset();
    const el = target(e);
    if (!el) return;
    picked = el;
    highlight(el);
    if (e.metaKey) return submit('');
    ui.el.textContent = label(el);
    ui.text.value = '';
    ui.note.hidden = false;
    grow();
    place(el.getBoundingClientRect());
    ui.text.focus();
  }

  function grow() {
    ui.text.style.height = 'auto';
    ui.text.style.height = ui.text.scrollHeight + 2 + 'px';
  }

  // Below the element when it fits, else above, clamped inside the viewport.
  function place(r) {
    const w = ui.note.offsetWidth, h = ui.note.offsetHeight;
    const top = r.bottom + 8 + h < innerHeight ? r.bottom + 8 : r.top - 8 - h;
    Object.assign(ui.note.style, {
      left: Math.min(Math.max(8, r.left), innerWidth - w - 8) + 'px',
      top: Math.min(Math.max(8, top), innerHeight - h - 8) + 'px',
    });
  }

  function styles(el) {
    const cs = getComputedStyle(el);
    return ['color', 'background-color', 'font-family', 'font-size', 'font-weight', 'line-height',
      'padding', 'margin', 'border-radius', 'display', 'gap']
      .map((k) => `${k}: ${cs.getPropertyValue(k)}`).join('; ');
  }

  function submit(comment) {
    const el = picked;
    if (!el) return;
    let selector = '';
    try { selector = finder(el, { timeoutMs: 200 }); } catch { selector = label(el); }
    const r = el.getBoundingClientRect();
    const payload = {
      type: 'annotation', comment: String(comment).slice(0, 4000), url: location.href, title: document.title,
      selector, tag: label(el), text: (el.innerText || '').trim().slice(0, 400),
      html: el.outerHTML.slice(0, 3000), styles: styles(el),
      rect: { x: r.left, y: r.top, width: r.width, height: r.height }, scrollX, scrollY,
    };
    // Hide our UI so Herm's screenshot shows the page; Herm calls done() after.
    host.style.display = 'none';
    requestAnimationFrame(() => requestAnimationFrame(() => post(payload)));
  }

  function reset() {
    picked = null;
    if (!ui) return;
    ui.note.hidden = true;
    ui.box.style.display = ui.tag.style.display = 'none';
  }

  function onKey(e) {
    if (enabled && e.key === 'Escape' && !inside(e)) { setEnabled(false); post({ type: 'mode', enabled: false }); }
  }

  // theme: Herm's palette as CSS custom properties, e.g. { accent: '#4f8cff' }.
  function setEnabled(on, theme) {
    enabled = !!on;
    if (enabled) mount(); else reset();
    if (host && theme) for (const [k, v] of Object.entries(theme)) host.style.setProperty('--' + k, v);
    if (host) host.style.display = enabled ? '' : 'none';
  }

  for (const t of ['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'contextmenu', 'auxclick'])
    addEventListener(t, onBlock, true);
  addEventListener('mousemove', onMove, true);
  addEventListener('keydown', onKey, true);

  window.__hermAnnotate = {
    setEnabled,
    done() { if (host) host.style.display = enabled ? '' : 'none'; reset(); },
    selection: () => String(getSelection() || '').slice(0, 4000),
  };
})();
