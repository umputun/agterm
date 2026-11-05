// runs in the app's own content world, since the document's JavaScript is off
(() => {
  const source = document.getElementById('agterm-markdown');
  const page = document.getElementById('agterm-page');
  if (!source || !page || typeof markdownit !== 'function') return;
  let images = {};
  try { images = JSON.parse(source.dataset.images || '{}'); } catch (_) { images = {}; }
  const refs = images.references || {}, uris = images.uris || [];
  const decoded = (text) => { try { return decodeURIComponent(text); } catch (_) { return text; } };

  const md = markdownit({
    html: false,
    linkify: false,
    highlight: (code, lang) => {
      if (!lang || typeof hljs === 'undefined' || !hljs.getLanguage(lang)) return '';
      try { return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (_) { return ''; }
    },
  });
  // only app-embedded data URIs are shown, so no authored source reaches the document;
  // placeholders keep repeated base64 payloads out of rendered markup
  const maxImages = 256;
  let shown = 0;
  md.renderer.rules.image = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    const key = decoded(token.attrGet('src') || '');
    const alt = md.utils.escapeHtml(self.renderInlineAsText(token.children || [], options, env));
    const index = Object.prototype.hasOwnProperty.call(refs, key) ? refs[key] : null;
    const uri = Number.isInteger(index) ? uris[index] : null;
    if (typeof uri === 'string' && uri.startsWith('data:image/') && shown < maxImages) {
      shown++;
      return `<img data-agterm-image="${index}" alt="${alt}">`;
    }
    return `<span class="agterm-alt">${alt || md.utils.escapeHtml(key)}</span>`;
  };
  // markdown-it knows no frontmatter: its closing `---` would turn the yaml into a setext heading
  let text = source.textContent, front = '';
  const fm = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
  if (fm) {
    const yaml = md.options.highlight(fm[1], 'yaml') || md.utils.escapeHtml(fm[1]);
    front = `<pre class="agterm-frontmatter"><code class="language-yaml">${yaml}</code></pre>`;
    text = text.slice(fm[0].length);
  }
  page.innerHTML = front + md.render(text);
  source.remove();
  for (const img of page.querySelectorAll('img[data-agterm-image]')) {
    img.src = uris[Number(img.dataset.agtermImage)];
    img.removeAttribute('data-agterm-image');
  }

  // a web link goes through the app's confirmed hand-off and a fragment scrolls in place; anything else
  // (about:, a relative file, another scheme) would navigate the page off its document, so it stays text
  for (const link of page.querySelectorAll('a[href]')) {
    const href = link.getAttribute('href');
    if (/^https?:\/\//i.test(href) || /^#[^#]*$/.test(href)) continue;
    link.removeAttribute('href');
  }

  // next keeps a run of identical headings linear; used still catches an authored `x-1` heading
  const used = new Set(), next = new Map();
  for (const heading of page.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
    const base = heading.textContent.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s/g, '-');
    let slug = base;
    if (used.has(slug)) {
      let n = next.get(base) || 1;
      while (used.has(`${base}-${n}`)) n++;
      slug = `${base}-${n}`;
      next.set(base, n + 1);
    }
    used.add(slug);
    heading.id = slug;
  }

  for (const item of page.querySelectorAll('li')) {
    const para = item.firstElementChild && item.firstElementChild.tagName === 'P' ? item.firstElementChild : null;
    const first = para ? para.firstChild : item.firstChild && item.firstChild.nodeType === Node.TEXT_NODE ? item.firstChild : null;
    const match = first && first.nodeType === Node.TEXT_NODE ? /^\[([ xX])\]\s/.exec(first.textContent) : null;
    if (!match) continue;
    first.textContent = first.textContent.slice(match[0].length);
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.disabled = true;
    box.checked = match[1] !== ' ';
    first.parentNode.insertBefore(box, first);
    item.classList.add('task');
  }
})();
