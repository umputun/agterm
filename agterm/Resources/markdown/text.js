// runs in the app's own content world, since the document's JavaScript is off
(() => {
  const source = document.getElementById('agterm-text');
  const page = document.getElementById('agterm-page');
  if (!source || !page) return;
  const text = source.textContent;
  const language = source.dataset.language;
  const target = Number(source.dataset.line);
  source.remove();

  const lines = text.split('\n');
  if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
  const gutter = document.createElement('div');
  gutter.className = 'agterm-gutter';
  gutter.textContent = lines.map((_, i) => i + 1).join('\n');

  const pre = document.createElement('pre');
  const code = document.createElement('code');
  code.textContent = text;
  // highlight.js escapes the text it returns, which makes its value the page's one markup sink
  if (language && typeof hljs !== 'undefined' && hljs.getLanguage(language)) {
    try { code.innerHTML = hljs.highlight(text, { language, ignoreIllegals: true }).value; } catch (_) { code.textContent = text; }
  }
  pre.appendChild(code);
  page.append(gutter, pre);

  if (!Number.isInteger(target) || target < 1 || target > lines.length) return;
  const style = getComputedStyle(pre);
  const band = document.createElement('div');
  band.className = 'agterm-band';
  band.style.top = `${parseFloat(style.paddingTop) + (target - 1) * parseFloat(style.lineHeight)}px`;
  page.prepend(band);
  band.scrollIntoView({ block: 'center' });
})();
