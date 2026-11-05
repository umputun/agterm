// runs in the app's own content world, since the document's JavaScript is off
(() => {
  const source = document.getElementById('agterm-text');
  const page = document.getElementById('agterm-page');
  if (!source || !page) return;
  const text = source.textContent;
  const language = source.dataset.language;
  const target = Number(source.dataset.line);
  const log = source.dataset.log !== undefined;
  source.remove();

  const lineCount = (value) => {
    const lines = value.split('\n');
    if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
    return value === '' ? 0 : lines.length;
  };

  const pre = document.createElement('pre');
  const code = document.createElement('code');
  const render = (value, lang) => {
    code.textContent = value;
    // highlight.js escapes the text it returns, which makes its value the page's one markup sink
    if (lang && typeof hljs !== 'undefined' && hljs.getLanguage(lang)) {
      try { code.innerHTML = hljs.highlight(value, { language: lang, ignoreIllegals: true }).value; } catch (_) { code.textContent = value; }
    }
  };
  render(text, language);
  pre.appendChild(code);

  if (log) {
    startLog();
    return;
  }

  const lines = text.split('\n');
  if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
  const gutter = document.createElement('div');
  gutter.className = 'agterm-gutter';
  gutter.textContent = lines.map((_, i) => i + 1).join('\n');
  page.append(gutter, pre);

  if (!Number.isInteger(target) || target < 1 || target > lines.length) return;
  const style = getComputedStyle(pre);
  const band = document.createElement('div');
  band.className = 'agterm-band';
  band.style.top = `${parseFloat(style.paddingTop) + (target - 1) * parseFloat(style.lineHeight)}px`;
  page.prepend(band);
  band.scrollIntoView({ block: 'center' });

  function startLog() {
    let following = source.dataset.following === 'true';
    let state = { clipped: source.hasAttribute('data-clipped'), waiting: source.hasAttribute('data-waiting'),
                  unreadable: source.hasAttribute('data-unreadable'), lines: lineCount(text) };
    const scroller = document.scrollingElement || document.documentElement;
    const bar = document.createElement('div');
    bar.className = 'agterm-logbar';
    const toggle = document.createElement('button');
    toggle.type = 'button';
    const info = document.createElement('span');
    bar.append(toggle, info);
    document.body.prepend(bar);
    page.append(pre);

    const drawBar = () => {
      toggle.textContent = following ? 'Follow: on' : 'Follow: paused - Resume';
      toggle.classList.toggle('agterm-paused', !following);
      const notes = [`last ${state.lines.toLocaleString('en-US')} lines`];
      if (state.clipped) notes.push('first line clipped');
      if (state.waiting) notes.push('waiting for file');
      if (state.unreadable) notes.push('unreadable data');
      info.textContent = notes.join(' · ');
    };
    const atBottom = () => scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 4;
    const toBottom = () => { scroller.scrollTop = scroller.scrollHeight; };
    const send = (body) => {
      try { window.webkit.messageHandlers.agtermLogScroll.postMessage(body); } catch (_) {}
    };
    const post = () => send({ following, top: scroller.scrollTop });

    // only a scroll the user started changes following, so a resize or a programmatic jump never pauses the page;
    // a held pointer, as on a scrollbar drag, keeps the intent until it is released
    let intent = 0;
    let held = false;
    const noteIntent = () => { intent = Date.now(); };
    ['wheel', 'keydown', 'touchstart'].forEach((kind) => window.addEventListener(kind, noteIntent, { passive: true }));
    window.addEventListener('pointerdown', () => { held = true; noteIntent(); }, { passive: true });
    ['pointerup', 'pointercancel'].forEach((kind) => window.addEventListener(kind, () => { held = false; noteIntent(); }, { passive: true }));
    let settle = 0;
    window.addEventListener('scroll', () => {
      if (!held && Date.now() - intent > 600) return;
      const bottom = atBottom();
      if (following !== bottom) {
        following = bottom;
        drawBar();
        post();
        return;
      }
      if (following) return;
      clearTimeout(settle);
      settle = setTimeout(post, 250);
    }, { passive: true });
    toggle.addEventListener('click', () => {
      following = !following;
      drawBar();
      if (following) toBottom();
      post();
    });

    window.agtermTextUpdate = (value, clipped, waiting, unreadable, lang) => {
      render(value, lang);
      state = { clipped, waiting, unreadable, lines: lineCount(value) };
      drawBar();
      if (following) toBottom();
    };
    window.agtermTextSetFollowing = (value) => {
      following = value;
      drawBar();
      if (following) toBottom();
    };

    drawBar();
    const anchor = Number(source.dataset.anchor);
    if (!following && Number.isFinite(anchor)) {
      scroller.scrollTop = anchor;
    } else {
      toBottom();
    }
    send({ ready: true });
  }
})();
