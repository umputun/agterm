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
  const escape = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  const render = (value, lang) => {
    code.textContent = value;
    // highlight.js escapes the text it returns; it and renderDiff's escaped rows are the page's only markup sinks
    if (lang && typeof hljs !== 'undefined' && hljs.getLanguage(lang)) {
      try { code.innerHTML = hljs.highlight(value, { language: lang, ignoreIllegals: true }).value; } catch (_) { code.textContent = value; }
    }
  };
  const rows = !log && source.dataset.diff !== undefined ? diffRows(text.split('\n')) : null;
  // a patch with no unified hunk (context, normal or combined format) keeps the diff grammar
  if (rows && rows.some((row) => row.kind !== '')) renderDiff(text.split('\n'), rows); else render(text, language);
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
    if (rows) paintRows(rows);
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
  const changes = rows ? startChanges(rows) : null;
  finder.start();
  window.addEventListener('keydown', keys);
  send({ ready: true });

  function glyph(path) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 16 16');
    const line = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    line.setAttribute('d', path);
    svg.append(line);
    return svg;
  }

  function control(path, title) {
    const button = document.createElement('button');
    button.type = 'button';
    button.title = title;
    button.setAttribute('aria-label', title);
    button.append(glyph(path));
    return button;
  }

  // matches TerminalSearchBar: change the two together
  function startSearch() {
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
    // queries this document's field sent and has not seen echoed yet, oldest first
    let pending = [];
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
    const report = () => send({ report: { revision, query, matches: offsets.length, current: offsets.length ? current + 1 : 0 } });

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
      if (own) {
        pending.push(value);
        send({ search: value });
      }
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
      // an echo of a query still pending here never touches the field, since later typing is on its way; anything
      // else, a control set or the echo of typing this document never saw, makes the page take the model's query
      set(value, from, typed) {
        if (from < revision) return;
        revision = from;
        const at = typed ? pending.indexOf(value) : -1;
        if (at >= 0) {
          pending = pending.slice(at + 1);
          if (value === query) report();
          return;
        }
        pending = [];
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

  // a row's kind is ' ', '-' or '+' inside a hunk, '\\' for the no-newline marker, and '' outside hunks; the hunk
  // counts decide where a hunk ends, so a changed row that reads like a header stays a change. `hunk` counts the
  // hunks, and `lang` is the language of the file the `+++` header names, from the page's path map.
  function diffRows(lines) {
    let files = new Map();
    try { files = new Map(Object.entries(JSON.parse(source.dataset.files || '{}'))); } catch (_) {}
    let old = 0, added = 0, hunk = 0, from = '', lang = null;
    return lines.map((row) => {
      if (old > 0 || added > 0) {
        // the no-newline marker belongs to the row before it and counts on neither side
        if (row.startsWith('\\')) return { kind: '\\', hunk, lang };
        const kind = row.startsWith('-') || row.startsWith('+') ? row[0] : ' ';
        if (kind !== '+') old -= 1;
        if (kind !== '-') added -= 1;
        if (old <= 0 && added <= 0) old = added = 0;
        return { kind, hunk, lang };
      }
      const path = row.slice(4).split('\t')[0];
      if (row.startsWith('--- ')) {
        from = path;
        lang = null;
      } else if (row.startsWith('+++ ')) {
        lang = files.get(path) || files.get(from) || null;
      }
      const counts = /^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/.exec(row);
      if (counts) {
        hunk += 1;
        old = counts[1] === undefined ? 1 : Number(counts[1]);
        added = counts[2] === undefined ? 1 : Number(counts[2]);
      }
      return { kind: '', hunk, lang: null };
    });
  }

  // every row is escaped or highlight.js output, which keeps the text exactly what the file holds; each hunk's two
  // sides are highlighted whole, so a comment or string opened on an earlier row keeps its color, and none leaks
  // across the lines a patch leaves out between hunks
  function renderDiff(lines, rows) {
    const marker = (row) => (row ? `<span class="agterm-marker">${escape(row.charAt(0))}</span>` : '');
    const html = lines.map((row, i) => {
      const { kind } = rows[i];
      if (kind === '') return row ? `<span class="hljs-meta">${escape(row)}</span>` : '';
      return kind === '\\' ? escape(row) : marker(row) + escape(row.slice(1));
    });
    const sides = new Map();
    rows.forEach((row, i) => {
      if (!row.lang || row.kind === '' || row.kind === '\\') return;
      if (!sides.has(row.hunk)) sides.set(row.hunk, { lang: row.lang, old: [], new: [] });
      const side = sides.get(row.hunk);
      if (row.kind !== '+') side.old.push(i);
      if (row.kind !== '-') side.new.push(i);
    });
    for (const side of sides.values()) {
      const highlight = (indexes) => highlightRows(indexes.map((i) => lines[i].slice(1)).join('\n'), side.lang);
      const old = highlight(side.old);
      side.old.forEach((i, n) => { if (rows[i].kind === '-') html[i] = marker(lines[i]) + old[n]; });
      const updated = highlight(side.new);
      side.new.forEach((i, n) => { html[i] = marker(lines[i]) + updated[n]; });
    }
    code.innerHTML = html.join('\n');
  }

  // highlight.js spans can cross rows, so each row closes what is open at its end and reopens it on the next
  function highlightRows(value, lang) {
    let html;
    try { html = hljs.highlight(value, { language: lang, ignoreIllegals: true }).value; } catch (_) { return value.split('\n').map(escape); }
    const out = [];
    const open = [];
    let row = '';
    for (const m of html.matchAll(/<span class="([^"]*)">|<\/span>|\n|[^<\n]+/g)) {
      if (m[0] === '\n') {
        out.push(row + '</span>'.repeat(open.length));
        row = open.map((c) => `<span class="${c}">`).join('');
        continue;
      }
      if (m[0] === '</span>') open.pop();
      if (m[1] !== undefined) open.push(m[1]);
      row += m[0];
    }
    out.push(row + '</span>'.repeat(open.length));
    return out;
  }

  // rows never wrap, so a run of added or removed rows is one band at its first row's offset
  function paintRows(rows) {
    page.classList.add('agterm-diff');
    const style = getComputedStyle(pre);
    const height = parseFloat(style.lineHeight);
    const inset = parseFloat(style.paddingTop);
    const bands = document.createDocumentFragment();
    for (let first = 0; first < rows.length; first++) {
      const kind = rows[first].kind;
      if (kind !== '-' && kind !== '+') continue;
      let last = first;
      while (last + 1 < rows.length && rows[last + 1].kind === kind) last++;
      const band = document.createElement('div');
      band.className = kind === '+' ? 'agterm-added' : 'agterm-removed';
      band.style.top = `${pre.offsetTop + inset + first * height}px`;
      band.style.height = `${(last - first + 1) * height}px`;
      bands.append(band);
      first = last;
    }
    page.prepend(bands);
  }

  // a change is one run of removed and added rows inside a hunk
  function changeBlocks(rows) {
    const blocks = [];
    let first = -1, last = -1;
    rows.forEach(({ kind }, index) => {
      if (kind === '\\') return;
      if (kind === '-' || kind === '+') {
        if (first < 0) first = index;
        last = index;
        return;
      }
      if (first >= 0) blocks.push([first, last]);
      first = -1;
    });
    if (first >= 0) blocks.push([first, last]);
    return blocks;
  }

  function startChanges(rows) {
    const blocks = changeBlocks(rows);
    let current = -1;
    const saved = Number(source.dataset.change);
    if (Number.isInteger(saved) && saved >= 1 && saved <= blocks.length) current = saved - 1;
    const report = () => send({ changes: { count: blocks.length, current: current + 1 } });
    if (!blocks.length) {
      report();
      return null;
    }

    const group = document.createElement('div');
    group.className = 'agterm-changes';
    const previous = control('M3.5 10.5 8 6l4.5 4.5', 'Previous change ([)');
    const next = control('M3.5 5.5 8 10l4.5-4.5', 'Next change (])');
    const label = document.createElement('span');
    group.append(previous, next, label);
    bar.prepend(group);
    const band = document.createElement('div');
    band.className = 'agterm-change';
    band.hidden = true;
    page.prepend(band);

    // rows never wrap, so a row's place is its index times the line height
    const style = getComputedStyle(pre);
    const height = parseFloat(style.lineHeight);
    const inset = parseFloat(style.paddingTop);
    // in document coordinates, which scrollTop measures; the band sits in the page, whose own top is the bar's room
    const origin = () => page.offsetTop + pre.offsetTop + inset;
    const topOf = (block) => origin() + block[0] * height;
    const bottomOf = (block) => origin() + (block[1] + 1) * height;
    const view = () => ({ top: scroller.scrollTop + bar.offsetHeight, bottom: scroller.scrollTop + scroller.clientHeight });
    const visible = (block) => {
      const { top, bottom } = view();
      return bottomOf(block) > top && topOf(block) < bottom;
    };

    const draw = () => {
      const count = blocks.length;
      label.textContent = current < 0 ? `${count} ${count === 1 ? 'change' : 'changes'}` : `change ${current + 1} of ${count}`;
      band.hidden = current < 0;
      if (current < 0) return;
      band.style.top = `${pre.offsetTop + inset + blocks[current][0] * height}px`;
      band.style.height = `${(blocks[current][1] - blocks[current][0] + 1) * height}px`;
    };
    // the change is brought into view only when its first row is not shown below the bar
    const reveal = () => {
      const { top, bottom } = view();
      const start = topOf(blocks[current]);
      if (start < top || start + height > bottom) scrollTo(start - bar.offsetHeight - (scroller.clientHeight - bar.offsetHeight) / 3);
    };
    // a step goes on from the current change while it is on screen, and from the view's top once the user scrolled
    // it away, so Next never jumps back to a change above what is shown
    const step = (forward) => {
      const count = blocks.length;
      if (current >= 0 && visible(blocks[current])) {
        current = (current + (forward ? 1 : count - 1)) % count;
      } else {
        const { top } = view();
        const below = blocks.findIndex((block) => topOf(block) >= top);
        if (forward) {
          current = below < 0 ? 0 : below;
        } else {
          current = (below < 0 ? count : below) - 1;
          if (current < 0) current = count - 1;
        }
      }
      draw();
      reveal();
      report();
      return { count, current: current + 1 };
    };
    previous.addEventListener('click', () => step(false));
    next.addEventListener('click', () => step(true));
    draw();
    report();
    return { step };
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

    window.agtermTextUpdate = (raw, clipped, waiting, unreadable, lang, shift) => {
      // line breaks as the parser left them in the first document, which LogFollower.shift counts the same way
      const value = raw.replace(/\r\n?/g, '\n');
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
      if (event.key === ']' && changes) { changes.step(true); return true; }
      if (event.key === '[' && changes) { changes.step(false); return true; }
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
  window.agtermTextChangeStep = (forward) => (changes ? changes.step(forward) : { count: 0, current: 0 });
  window.agtermTextFocusSearch = () => {
    finder.field.focus();
    finder.field.select();
  };
})();
