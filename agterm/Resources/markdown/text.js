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
  // text with escape sequences shows its SGR colors instead of the language's, since they are the writer's
  const render = (parsed, lang) => {
    if (parsed.runs) {
      paintRuns(parsed.runs);
      return;
    }
    code.textContent = parsed.plain;
    // highlight.js escapes the text it returns; it and renderDiff's escaped rows are the page's only markup sinks
    if (lang && typeof hljs !== 'undefined' && hljs.getLanguage(lang)) {
      try { code.innerHTML = hljs.highlight(parsed.plain, { language: lang, ignoreIllegals: true }).value; } catch (_) { code.textContent = parsed.plain; }
    }
  };
  const parsed = ansi(text);
  text = parsed.plain;
  const rows = !log && source.dataset.diff !== undefined ? diffRows(text.split('\n')) : null;
  // a patch with no unified hunk (context, normal or combined format) keeps the diff grammar; a colored patch
  // shows the diff renderer's bands and syntax, which say what git's colors do
  if (rows && rows.some((row) => row.kind !== '')) renderDiff(text.split('\n'), rows); else render(parsed, language);
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

  let wrapped = source.dataset.wrap !== undefined;
  document.body.classList.toggle('agterm-wrapped', wrapped);
  // the row each line starts on, then the row count; measured on first use while wrapped, dropped by every reflow
  let lineRows = null;
  const rowStart = (line) => {
    if (!wrapped) return line;
    if (!lineRows) lineRows = measureRows(lineCount());
    return lineRows[line];
  };
  const placers = [];

  let following = false;
  const logControls = log ? startLog() : null;
  if (!log) {
    const count = lineCount();
    const gutter = document.createElement('div');
    gutter.className = 'agterm-gutter';
    gutter.textContent = Array.from({ length: count }, (_, i) => i + 1).join('\n');
    page.append(gutter, pre);
    // a wrapped line's number heads its first row, and blank rows fill the rest
    const drawGutter = () => {
      gutter.textContent = Array.from({ length: count }, (_, i) => `${i + 1}${'\n'.repeat(rowStart(i + 1) - rowStart(i) - 1)}`)
        .join('\n');
    };
    if (wrapped) drawGutter();
    placers.push(drawGutter);
    if (rows) paintRows(rows);
    if (Number.isInteger(target) && target >= 1 && target <= count) {
      const style = getComputedStyle(pre);
      const band = document.createElement('div');
      band.className = 'agterm-band';
      const placeBand = () => {
        const height = parseFloat(style.lineHeight);
        band.style.top = `${parseFloat(style.paddingTop) + rowStart(target - 1) * height}px`;
        band.style.height = `${(rowStart(target) - rowStart(target - 1)) * height}px`;
      };
      placeBand();
      placers.push(placeBand);
      page.prepend(band);
      band.scrollIntoView({ block: 'center' });
      lastTop = scroller.scrollTop;
    }
    const anchor = Number(source.dataset.anchor);
    if (Number.isFinite(anchor)) scrollTo(anchor);
  }
  const changes = rows ? startChanges(rows) : null;
  const wrapper = startWrap();
  finder.start();
  window.addEventListener('keydown', keys);
  window.addEventListener('resize', () => {
    if (!wrapped) return;
    lineRows = null;
    placers.forEach((place) => place());
    if (log && following) scrollTo(scroller.scrollHeight);
  });
  send({ ready: true });

  // lines as the gutter numbers them: a final line break opens no line of its own
  function lineCount() {
    let count = 1;
    for (let at = text.indexOf('\n'); at >= 0; at = text.indexOf('\n', at + 1)) count += 1;
    return count > 1 && text.endsWith('\n') ? count - 1 : count;
  }

  // escapes are dropped by the grammar of TerminalText.strippingEscapes, so the Swift side reads a diff's headers
  // the same way; an unfinished sequence at the end of a growing file is dropped and reparsed with the next read
  function ansi(value) {
    if (!value.includes('\x1b')) return { plain: value, runs: null };
    const runs = [];
    let style = {};
    let start = 0;
    const take = (end) => {
      if (end > start) runs.push({ text: value.slice(start, end), style });
    };
    for (let at = value.indexOf('\x1b'); at >= 0; at = value.indexOf('\x1b', start)) {
      take(at);
      const kind = value.charCodeAt(at + 1);
      let end = at + 2;
      if (kind === 0x5b) {
        while (end < value.length && !(value.charCodeAt(end) >= 0x40 && value.charCodeAt(end) <= 0x7e)) end += 1;
        if (value[end] === 'm') style = sgr(style, value.slice(at + 2, end));
        end += 1;
      } else if (kind === 0x5d) {
        while (end < value.length && value.charCodeAt(end) !== 0x07 && value.charCodeAt(end) !== 0x1b) end += 1;
        end += value.charCodeAt(end) === 0x1b ? 2 : 1;
      } else if (kind >= 0x20 && kind <= 0x2f) {
        while (end < value.length && value.charCodeAt(end) >= 0x20 && value.charCodeAt(end) <= 0x2f) end += 1;
        end += 1;
      }
      start = Math.min(end, value.length);
    }
    take(value.length);
    return { plain: runs.map((run) => run.text).join(''), runs };
  }

  // a style is { fg, bg, bold }, colors as CSS values built here from numbers only
  function sgr(style, params) {
    const next = { ...style };
    const codes = params.split(';');
    // [5, n] or [2, r, g, b]; the colon form may put a color space id before r, g, b
    const extended = (args) => (args[0] === 5 ? indexed(args[1]) : args[0] === 2 ? rgb(...args.slice(-3)) : undefined);
    const setColor = (n, color) => { if (color) next[n === 38 ? 'fg' : 'bg'] = color; };
    for (let at = 0; at < codes.length; at += 1) {
      // colon subparameters belong to one attribute, so their zeros are never resets
      const [first, ...sub] = codes[at].split(':').map(Number);
      const n = first || 0;
      if (sub.length) {
        if (n === 38 || n === 48) setColor(n, extended(sub));
        continue;
      }
      if (n === 0) { delete next.fg; delete next.bg; delete next.bold; }
      else if (n === 1) next.bold = true;
      else if (n === 22) delete next.bold;
      else if (n >= 30 && n <= 37) next.fg = indexed(n - 30);
      else if (n >= 90 && n <= 97) next.fg = indexed(n - 82);
      else if (n === 39) delete next.fg;
      else if (n >= 40 && n <= 47) next.bg = indexed(n - 40);
      else if (n >= 100 && n <= 107) next.bg = indexed(n - 92);
      else if (n === 49) delete next.bg;
      else if (n === 38 || n === 48) {
        const selector = Number(codes[at + 1]);
        const used = selector === 5 ? 2 : selector === 2 ? 4 : codes.length;
        setColor(n, extended(codes.slice(at + 1, at + 1 + used).map(Number)));
        at += used;
      }
    }
    return next;
  }

  // the theme's 16 colors when it supplies them, xterm's otherwise; 16 to 255 are xterm's cube and gray ramp
  function indexed(n) {
    const xterm = ['#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
      '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff'];
    if (!Number.isInteger(n) || n < 0 || n > 255) return undefined;
    if (n < 16) return `var(--agterm-color-${n}, ${xterm[n]})`;
    if (n >= 232) return rgb(8 + (n - 232) * 10, 8 + (n - 232) * 10, 8 + (n - 232) * 10);
    const level = (v) => (v ? 55 + v * 40 : 0);
    return rgb(level(Math.floor((n - 16) / 36)), level(Math.floor((n - 16) / 6) % 6), level((n - 16) % 6));
  }

  function rgb(r, g, b) {
    const ok = [r, g, b].every((v) => Number.isInteger(v) && v >= 0 && v <= 255);
    return ok ? `rgb(${r}, ${g}, ${b})` : undefined;
  }

  function paintRuns(runs) {
    const fragment = document.createDocumentFragment();
    for (const { text: part, style } of runs) {
      if (!style.fg && !style.bg && !style.bold) {
        fragment.append(part);
        continue;
      }
      const span = document.createElement('span');
      if (style.fg) span.style.color = style.fg;
      if (style.bg) span.style.backgroundColor = style.bg;
      if (style.bold) span.style.fontWeight = 'bold';
      span.textContent = part;
      fragment.append(span);
    }
    code.replaceChildren(fragment);
  }

  // every row is one line box of the same height, so a line starts one row below the newline that ends the line
  // before it, and the text ends on the row of the code element's last fragment. A line's first character is never
  // measured: on a diff row it is the zero-size marker, whose rect is empty.
  function measureRows(count) {
    const style = getComputedStyle(pre);
    const height = parseFloat(style.lineHeight);
    const origin = pre.getBoundingClientRect().top + parseFloat(style.paddingTop);
    const rowOf = (rect) => Math.floor((rect.top + rect.height / 2 - origin) / height);
    const starts = new Int32Array(count + 1);
    const range = document.createRange();
    const walker = document.createTreeWalker(code, NodeFilter.SHOW_TEXT);
    let line = 1;
    for (let node = walker.nextNode(); node && line < count; node = walker.nextNode()) {
      for (let at = node.data.indexOf('\n'); at >= 0 && line < count; at = node.data.indexOf('\n', at + 1)) {
        range.setStart(node, at);
        range.setEnd(node, at + 1);
        starts[line] = rowOf(range.getBoundingClientRect()) + 1;
        line += 1;
      }
    }
    const fragments = code.getClientRects();
    starts[count] = fragments.length ? rowOf(fragments[fragments.length - 1]) + 1 : count;
    return starts;
  }

  // a toggle keeps the line under the bar there, or a following log at its end, and moves through scrollTo, so the
  // reflow never reads as the user scrolling
  function startWrap() {
    const toggle = document.createElement('button');
    toggle.type = 'button';
    toggle.className = 'agterm-wrap';
    toggle.title = 'Wrap long lines (w)';
    bar.insertBefore(toggle, bar.querySelector('.agterm-search'));
    const draw = () => {
      toggle.textContent = wrapped ? 'Wrap: on' : 'Wrap: off';
      toggle.setAttribute('aria-pressed', String(wrapped));
    };
    const lineTop = (line) => {
      const style = getComputedStyle(pre);
      return page.offsetTop + pre.offsetTop + parseFloat(style.paddingTop) + rowStart(line) * parseFloat(style.lineHeight);
    };
    const topLine = () => {
      const view = scroller.scrollTop + bar.offsetHeight;
      let low = 0, high = lineCount() - 1;
      while (low < high) {
        const mid = (low + high + 1) >> 1;
        if (lineTop(mid) <= view) low = mid; else high = mid - 1;
      }
      return low;
    };
    const set = (value, own) => {
      if (value === wrapped) return;
      const line = topLine();
      // above the first line, as at the page's top, the gap is kept; inside a line its top goes under the bar
      const gap = Math.min(0, scroller.scrollTop + bar.offsetHeight - lineTop(line));
      wrapped = value;
      lineRows = null;
      document.body.classList.toggle('agterm-wrapped', wrapped);
      placers.forEach((place) => place());
      scrollTo(log && following ? scroller.scrollHeight : lineTop(line) - bar.offsetHeight + gap);
      draw();
      if (own) send({ wrap: wrapped });
      // the app reopens a paused log at the offset it was last told
      if (log) logControls.post();
    };
    toggle.addEventListener('click', () => set(!wrapped, true));
    draw();
    return {
      toggle: () => set(!wrapped, true),
      set: (value) => set(value, false),
    };
  }

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
      // a match's top grows with its offset, wrapped or not, so the first one in view is a binary search
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

  function paintRows(rows) {
    page.classList.add('agterm-diff');
    const style = getComputedStyle(pre);
    const bands = document.createDocumentFragment();
    const runs = [];
    for (let first = 0; first < rows.length; first++) {
      const kind = rows[first].kind;
      if (kind !== '-' && kind !== '+') continue;
      let last = first;
      while (last + 1 < rows.length && rows[last + 1].kind === kind) last++;
      const band = document.createElement('div');
      band.className = kind === '+' ? 'agterm-added' : 'agterm-removed';
      runs.push({ band, first, last });
      bands.append(band);
      first = last;
    }
    const place = () => {
      const height = parseFloat(style.lineHeight);
      const inset = pre.offsetTop + parseFloat(style.paddingTop);
      for (const { band, first, last } of runs) {
        band.style.top = `${inset + rowStart(first) * height}px`;
        band.style.height = `${(rowStart(last + 1) - rowStart(first)) * height}px`;
      }
    };
    place();
    placers.push(place);
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

    const style = getComputedStyle(pre);
    const height = parseFloat(style.lineHeight);
    const inset = parseFloat(style.paddingTop);
    // in document coordinates, which scrollTop measures; the band sits in the page, whose own top is the bar's room
    const origin = () => page.offsetTop + pre.offsetTop + inset;
    const topOf = (block) => origin() + rowStart(block[0]) * height;
    const bottomOf = (block) => origin() + rowStart(block[1] + 1) * height;
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
      band.style.top = `${pre.offsetTop + inset + rowStart(blocks[current][0]) * height}px`;
      band.style.height = `${(rowStart(blocks[current][1] + 1) - rowStart(blocks[current][0])) * height}px`;
    };
    placers.push(draw);
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
      if (following) {
        toggle.textContent = 'Follow: on';
      } else {
        const prefix = document.createElement('span');
        prefix.className = 'agterm-prefix';
        prefix.textContent = 'Follow: paused - ';
        toggle.replaceChildren(prefix, 'Resume');
      }
      toggle.setAttribute('aria-label', toggle.textContent);
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
      const update = ansi(raw.replace(/\r\n?/g, '\n'));
      render(update, lang);
      lineRows = null;
      state = { clipped, waiting, unreadable };
      finder.update(update.plain, shift || { dropped: 0, cut: false, replaced: false });
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
      if (event.key === 'w') { wrapper.toggle(); return true; }
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
  window.agtermTextSetWrap = (value) => wrapper.set(value === true);
  window.agtermTextChangeStep = (forward) => (changes ? changes.step(forward) : { count: 0, current: 0 });
  window.agtermTextFocusSearch = () => {
    finder.field.focus();
    finder.field.select();
  };
})();
