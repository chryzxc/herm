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
      .box{position:fixed;border:2px solid #4f8cff;background:rgba(79,140,255,.12);border-radius:3px;display:none;box-sizing:border-box}
      .tag{position:fixed;font:600 11px -apple-system,system-ui,sans-serif;color:#fff;background:#4f8cff;padding:2px 6px;border-radius:4px;display:none;white-space:nowrap}
      .note{position:fixed;width:280px;pointer-events:auto;background:#1d1f23;color:#eee;border:1px solid #3a3d44;border-radius:10px;padding:8px;box-shadow:0 8px 24px rgba(0,0,0,.35);font:13px -apple-system,system-ui,sans-serif}
      .note[hidden]{display:none}
      textarea{width:100%;box-sizing:border-box;height:64px;resize:none;background:#111316;color:inherit;border:1px solid #3a3d44;border-radius:6px;padding:6px;font:inherit;outline:none}
      .row{display:flex;justify-content:flex-end;gap:6px;margin-top:6px}
      button{font:inherit;border:0;border-radius:6px;padding:4px 10px;cursor:pointer;background:#2c2f35;color:inherit}
      button[type=submit]{background:#4f8cff;color:#fff}
    </style><div class="box"></div><div class="tag"></div>
    <form class="note" hidden><textarea placeholder="What should change? (Enter to send)"></textarea>
    <div class="row"><button type="button" class="cancel">Cancel</button><button type="submit">Send to chat</button></div></form>`;
    ui = { box: root.querySelector('.box'), tag: root.querySelector('.tag'), note: root.querySelector('.note') };
    ui.text = ui.note.querySelector('textarea');
    ui.note.addEventListener('submit', (e) => { e.preventDefault(); submit(ui.text.value); });
    ui.note.querySelector('.cancel').addEventListener('click', reset);
    ui.text.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(ui.text.value); }
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
    const r = el.getBoundingClientRect();
    const below = r.bottom + 150 < innerHeight;
    Object.assign(ui.note.style, {
      left: Math.min(Math.max(8, r.left), innerWidth - 290) + 'px',
      top: (below ? r.bottom + 8 : Math.max(8, r.top - 150)) + 'px',
    });
    ui.note.hidden = false;
    ui.text.value = '';
    ui.text.focus();
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

  function setEnabled(on) {
    enabled = !!on;
    if (enabled) mount(); else reset();
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
