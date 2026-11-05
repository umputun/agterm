// runs in the app's own content world, since the document's JavaScript is off
(() => {
  const source = document.getElementById('agterm-text');
  const page = document.getElementById('agterm-page');
  if (!source || !page) return;
  let text = source.textContent;
  const language = source.dataset.language;
  const target = Number(source.dataset.line);
  const log = source.dataset.log !== undefined;
  source.remove();


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

  const scroller = document.scrollingElement || document.documentElement;
  const send = (body) => {
    try { window.webkit.messageHandlers.agtermTextPage.postMessage(body); } catch (_) {}
  };
  // the vertical position last seen, kept across programmatic moves, so a horizontal scroll or a jump the page
  // made itself never reads as the user scrolling
  let lastTop = scroller.scrollTop;
  const scrollTo = (top) => {
    scroller.scrollTop = top;
    lastTop = scroller.scrollTop;
  };

  const bar = document.createElement('div');
  bar.className = 'agterm-bar';
  document.body.prepend(bar);
  const finder = startSearch();

  let following = false;
  const logControls = log ? startLog() : null;
  if (!log) {
    const lines = text.split('\n');
    if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
    const gutter = document.createElement('div');
    gutter.className = 'agterm-gutter';
    gutter.textContent = lines.map((_, i) => i + 1).join('\n');
    page.append(gutter, pre);
    if (Number.isInteger(target) && target >= 1 && target <= lines.length) {
      const style = getComputedStyle(pre);
      const band = document.createElement('div');
      band.className = 'agterm-band';
      band.style.top = `${parseFloat(style.paddingTop) + (target - 1) * parseFloat(style.lineHeight)}px`;
      page.prepend(band);
      band.scrollIntoView({ block: 'center' });
      lastTop = scroller.scrollTop;
    }
    const anchor = Number(source.dataset.anchor);
    if (Number.isFinite(anchor)) scrollTo(anchor);
  }
  finder.start();
  window.addEventListener('keydown', keys);
  send({ ready: true });

  function startSearch() {
    // matches TerminalSearchBar: change the two together
    const glyph = (path) => {
      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.setAttribute('viewBox', '0 0 16 16');
      const line = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      line.setAttribute('d', path);
      svg.append(line);
      return svg;
    };
    const control = (path, title) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.title = title;
      button.setAttribute('aria-label', title);
      button.append(glyph(path));
      return button;
    };
    const box = document.createElement('div');
    box.className = 'agterm-search';
    const field = document.createElement('input');
    field.type = 'text';
    field.placeholder = 'Find';
    field.spellcheck = false;
    field.autocomplete = 'off';
    const counter = document.createElement('span');
    counter.className = 'agterm-count';
    const previous = control('M3.5 10.5 8 6l4.5 4.5', 'Previous match');
    const next = control('M3.5 5.5 8 10l4.5-4.5', 'Next match');
    const close = control('M4 4l8 8M12 4l-8 8', 'Close search');
    const magnifier = glyph('M7 2.5a4.5 4.5 0 1 0 0 9 4.5 4.5 0 0 0 0-9zM10.3 10.3 14 14');
    magnifier.classList.add('agterm-magnifier');
    box.append(magnifier, field, counter, previous, next, close);
    bar.append(box);

    const painting = typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight === 'function';
    const marks = painting ? new Highlight() : null;
    const mark = painting ? new Highlight() : null;
    if (painting) {
      mark.priority = 1;
      CSS.highlights.set('agterm-match', marks);
      CSS.highlights.set('agterm-current', mark);
    }
    const paintLimit = 5000;
    let query = source.dataset.query || '';
    let revision = Number(source.dataset.revision) || 0;
    let offsets = new Int32Array(0);
    let lengths = new Int32Array(0);
    let current = -1;
    let windowStart = -1;
    let nodes = [];
    let starts = new Int32Array(0);

    // every text node under the code element and where it starts in its text, rebuilt with each render
    const mapNodes = () => {
      nodes = [];
      const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT);
      const found = [];
      let at = 0;
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        nodes.push(node);
        found.push(at);
        at += node.data.length;
      }
      starts = Int32Array.from(found);
    };
    const nodeAt = (offset) => {
      let low = 0, high = starts.length - 1;
      while (low < high) {
        const mid = (low + high + 1) >> 1;
        if (starts[mid] <= offset) low = mid; else high = mid - 1;
      }
      return low;
    };
    const rangeOf = (index) => {
      const begin = offsets[index], end = begin + lengths[index];
      const first = nodeAt(begin), last = nodeAt(end - 1);
      const range = document.createRange();
      range.setStart(nodes[first], begin - starts[first]);
      range.setEnd(nodes[last], end - starts[last]);
      return range;
    };
    // the first match index at or after `offset`
    const firstFrom = (offset) => {
      let low = 0, high = offsets.length;
      while (low < high) {
        const mid = (low + high) >> 1;
        if (offsets[mid] < offset) low = mid + 1; else high = mid;
      }
      return low;
    };

    // matches are found in the whole text, so one crossing highlight.js spans counts, and never overlap
    const find = () => {
      const found = [], sizes = [];
      if (query) {
        const pattern = new RegExp(query.replace(/[\\^$.*+?()[\]{}|/]/g, '\\$&'), 'giu');
        for (let hit = pattern.exec(text); hit; hit = pattern.exec(text)) {
          found.push(hit.index);
          sizes.push(hit[0].length);
        }
      }
      offsets = Int32Array.from(found);
      lengths = Int32Array.from(sizes);
    };

    const paint = (force) => {
      if (!painting) return;
      if (!offsets.length) {
        marks.clear();
        mark.clear();
        windowStart = -1;
        return;
      }
      const span = Math.min(paintLimit, offsets.length);
      const focus = Math.max(current, 0);
      if (force || windowStart < 0 || focus < windowStart || focus >= windowStart + span) {
        windowStart = Math.max(0, Math.min(focus - (span >> 1), offsets.length - span));
        marks.clear();
        for (let i = windowStart; i < windowStart + span; i += 1) marks.add(rangeOf(i));
      }
      mark.clear();
      if (current >= 0) mark.add(rangeOf(current));
    };

    const draw = () => {
      counter.textContent = !query ? '' : offsets.length ? `${current + 1} of ${offsets.length}` : 'no matches';
      previous.disabled = next.disabled = offsets.length === 0;
      close.disabled = query === '';
    };
    const report = () => send({ report: { revision, matches: offsets.length, current: offsets.length ? current + 1 : 0 } });

    // the match is brought into view only when it is not already shown below the bar
    const reveal = () => {
      if (current < 0) return;
      const rect = rangeOf(current).getBoundingClientRect();
      const top = bar.offsetHeight, bottom = scroller.clientHeight;
      if (rect.top < top || rect.bottom > bottom) scrollTo(scroller.scrollTop + rect.top - top - (bottom - top) / 3);
      if (rect.left < 0 || rect.right > scroller.clientWidth) scroller.scrollLeft += rect.left - scroller.clientWidth / 3;
    };

    // a fresh query starts at the first match at or below the view's top, or at the last one on a following page
    const pick = () => {
      if (!offsets.length) { current = -1; return; }
      if (log && following) { current = offsets.length - 1; return; }
      // lines never wrap, so a match's top grows with its offset and the first one in view is a binary search
      const top = bar.offsetHeight;
      let low = 0, high = offsets.length;
      while (low < high) {
        const mid = (low + high) >> 1;
        if (rangeOf(mid).getBoundingClientRect().top < top) low = mid + 1; else high = mid;
      }
      current = low < offsets.length ? low : 0;
    };

    const run = (move) => {
      find();
      pick();
      paint(true);
      draw();
      if (move && !(log && following)) reveal();
      report();
    };

    // a jump pauses a following page before it moves, and moves through scrollTo, so the scroll handler sees no
    // user scroll and cannot resume following at the bottom
    const jump = (forward) => {
      if (!offsets.length) return;
      if (log && following) logControls.pause();
      current = (current + (forward ? 1 : offsets.length - 1)) % offsets.length;
      paint(false);
      draw();
      reveal();
      report();
      if (log) logControls.post();
    };

    const setQuery = (value, own) => {
      query = value;
      if (own) send({ search: value });
      run(true);
    };
    field.addEventListener('input', () => setQuery(field.value, true));
    field.addEventListener('keydown', (event) => {
      event.stopPropagation();
      if (event.key === 'Enter') {
        event.preventDefault();
        jump(!event.shiftKey);
      } else if (event.key === 'Escape') {
        event.preventDefault();
        clear();
      }
    });
    const clear = () => {
      field.value = '';
      setQuery('', true);
      field.blur();
    };
    previous.addEventListener('click', () => jump(false));
    next.addEventListener('click', () => jump(true));
    close.addEventListener('click', clear);

    // the match a log update keeps: its line and which occurrence on that line it is
    const anchorOf = () => {
      if (current < 0) return null;
      const offset = offsets[current];
      const lineStart = text.lastIndexOf('\n', offset - 1) + 1;
      let line = 0;
      for (let at = text.indexOf('\n'); at >= 0 && at < lineStart; at = text.indexOf('\n', at + 1)) line += 1;
      return { line, occurrence: current - firstFrom(lineStart) };
    };
    const restore = (anchor, shift) => {
      if (!anchor || shift.replaced) return false;
      const line = anchor.line - shift.dropped;
      if (line < 0 || (shift.cut && line === 0)) return false;
      let lineStart = 0;
      for (let i = 0; i < line; i += 1) {
        const at = text.indexOf('\n', lineStart);
        if (at < 0) return false;
        lineStart = at + 1;
      }
      const lineEnd = text.indexOf('\n', lineStart);
      const index = firstFrom(lineStart) + anchor.occurrence;
      if (index >= offsets.length || (lineEnd >= 0 && offsets[index] >= lineEnd)) return false;
      current = index;
      return true;
    };

    return {
      field,
      jump,
      hasQuery: () => query !== '',
      start() {
        mapNodes();
        field.value = query;
        find();
        const saved = Number(source.dataset.current);
        if (Number.isInteger(saved) && saved >= 1 && saved <= offsets.length) current = saved - 1; else pick();
        paint(true);
        draw();
        if (query) report();
      },
      // a log update keeps the current match where its line still is, and never scrolls for it
      update(value, shift) {
        const anchor = anchorOf();
        text = value;
        mapNodes();
        find();
        if (!restore(anchor, shift)) pick();
        paint(true);
        draw();
        if (query) report();
      },
      // a revision the field typed is an echo: it never touches the field, and reports only once the page's query
      // is that revision's, so counts for later typing never land under an older revision
      set(value, from, typed) {
        if (from < revision) return;
        revision = from;
        if (typed) {
          if (value === query) report();
          return;
        }
        if (value !== query) {
          field.value = value;
          setQuery(value, false);
          return;
        }
        report();
      },
      step(forward, value, from) {
        this.set(value, from, false);
        jump(forward);
        return { matches: offsets.length, current: offsets.length ? current + 1 : 0 };
      },
    };
  }

  function startLog() {
    following = source.dataset.following === 'true';
    let state = { clipped: source.hasAttribute('data-clipped'), waiting: source.hasAttribute('data-waiting'),
                  unreadable: source.hasAttribute('data-unreadable') };
    const controls = document.createElement('div');
    controls.className = 'agterm-logbar';
    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.title = 'Follow or pause (F)';
    const info = document.createElement('span');
    controls.append(toggle, info);
    bar.prepend(controls);
    page.append(pre);

    const drawBar = () => {
      toggle.textContent = following ? 'Follow: on' : 'Follow: paused - Resume';
      toggle.classList.toggle('agterm-paused', !following);
      const notes = [];
      if (state.clipped) notes.push('first line clipped');
      if (state.waiting) notes.push('waiting for file');
      if (state.unreadable) notes.push('unreadable data');
      info.textContent = notes.join(' · ');
    };
    const atBottom = () => scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 4;
    const toBottom = () => scrollTo(scroller.scrollHeight);
    const post = () => send({ following, top: scroller.scrollTop });
    const setFollowing = (value) => {
      following = value;
      drawBar();
      if (following) toBottom();
      post();
    };

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
      const vertical = scroller.scrollTop !== lastTop;
      lastTop = scroller.scrollTop;
      if (!vertical || (!held && Date.now() - intent > 600)) return;
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
    toggle.addEventListener('click', () => setFollowing(!following));

    window.agtermTextUpdate = (value, clipped, waiting, unreadable, lang, shift) => {
      render(value, lang);
      state = { clipped, waiting, unreadable };
      finder.update(value, shift || { dropped: 0, cut: false, replaced: false });
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
      scrollTo(anchor);
    } else {
      toBottom();
    }
    return {
      post,
      pause() {
        following = false;
        drawBar();
      },
      toggle: () => setFollowing(!following),
      bottom: () => setFollowing(true),
      top() {
        following = false;
        drawBar();
        scrollTo(0);
        post();
      },
    };
  }

  // page keys act outside the field; the field handles its own Return and Escape
  function keys(event) {
    if (event.target === finder.field || event.metaKey || event.ctrlKey || event.altKey) return;
    const handled = (() => {
      if (event.key === '/') {
        finder.field.focus();
        finder.field.select();
        return true;
      }
      if (event.key === 'n' && finder.hasQuery()) { finder.jump(true); return true; }
      if (event.key === 'N' && finder.hasQuery()) { finder.jump(false); return true; }
      if (!logControls) return false;
      if (event.key === 'F') { logControls.toggle(); return true; }
      if (event.key === 'G' || event.key === 'End') { logControls.bottom(); return true; }
      if (event.key === 'g' || event.key === 'Home') { logControls.top(); return true; }
      return false;
    })();
    if (handled) event.preventDefault();
  }

  window.agtermTextSearchSet = (query, revision, typed) => finder.set(query, revision, typed === true);
  window.agtermTextSearchStep = (forward, query, revision) => finder.step(forward, query, revision);
  window.agtermTextFocusSearch = () => {
    finder.field.focus();
    finder.field.select();
  };
})();
