// Buch → PDF – a bookmarklet of Scriba: a book made of web pages becomes one page, then the browser's "Print"
// opens – "Save as PDF" there. Moodle books: their own print view · mdBook and others with "Print this book": that page · otherwise page after page
// along "Weiter", "Next" or rel=next (same site only, at most 500 pages). Protected e-book readers stay as they are.
// docs/index.html turns this file into the bookmark: full-line comments go, the rest is the code.
(async () => {
if (window.__buchPdf) return;
window.__buchPdf = 1;
const MAX = window.__buchPdfMax || 500;
const box = document.createElement('div');
box.id = 'buch-pdf-box';
box.style.cssText = 'all:initial;position:fixed;z-index:2147483647;top:16px;right:16px;display:flex;gap:12px;align-items:center;padding:12px 16px;border-radius:14px;background:#0b0f12;color:#eef2ee;font:14px/1.4 -apple-system,system-ui,sans-serif;box-shadow:0 10px 40px rgba(0,0,0,.35)';
box.innerHTML = '<b style="color:#f8b8d0;font-weight:600">Buch → PDF</b><span>…</span><button title="Abbrechen" style="all:unset;cursor:pointer;opacity:.6;padding:0 2px">✕</button>';
let stop = false;
const say = t => { box.children[1].textContent = t; };
box.children[2].onclick = () => { stop = true; box.remove(); window.__buchPdf = 0; };
document.body.appendChild(box);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const clean = u => u.split('#')[0];

// a page of the same site, as a document whose links and pictures point to the right place
const parse = (html, url) => {
const d = new DOMParser().parseFromString(html, 'text/html');
const b = d.createElement('base');
b.href = url;
d.head.prepend(b);
return d;
};
const fetchDoc = async url => {
const r = await fetch(url, { credentials: 'include' });
if (!r.ok) throw Error('HTTP ' + r.status);
return parse(await r.text(), r.url);
};
// pages that build themselves with JavaScript: in a hidden frame
const frameDoc = url => new Promise(res => {
const f = document.createElement('iframe');
f.style.cssText = 'position:fixed;left:-10000px;top:0;width:1100px;height:900px';
f.onload = () => setTimeout(() => { let d = null; try { d = f.contentDocument; } catch (e) {} res([d, f]); }, 1500);
f.src = url;
document.body.appendChild(f);
});

// the content of a page, without navigation, menus and buttons → HTML
const JUNK = /(^|[\s_-])(nav|navbar|navigation|menu|sidebar|breadcrumbs?|footer|cookie|banner|toolbar|pagination|share|skip)([\s_-]|$)/i;
const pick = (doc, sel) => {
for (const s of sel || ['.book_content', 'main article', 'article', 'main', '[role=main]', '#region-main', '#content', '.content', '#main']) {
const all = [...doc.querySelectorAll(s)];
if (all.length && all.reduce((n, e) => n + e.textContent.trim().length, 0) > 200) return all;
}
return [doc.body];
};
const html = (doc, sel) => pick(doc, sel).map(root => {
const c = root.cloneNode(true);
c.querySelectorAll('script,style,noscript,template,nav,aside,form,button,iframe,dialog,#buch-pdf-box,[role=navigation],[role=banner],[role=contentinfo]').forEach(e => e.remove());
c.querySelectorAll('[class],[id]').forEach(e => {
if (JUNK.test((e.className && e.className.baseVal === undefined ? e.className : '') + ' ' + e.id) && e.textContent.trim().length < 400) e.remove();
});
c.querySelectorAll('img').forEach(i => {
const lazy = i.getAttribute('data-src') || i.getAttribute('data-lazy-src') || i.getAttribute('data-original');
if (lazy) i.setAttribute('src', new URL(lazy, doc.baseURI).href);
else if (i.getAttribute('src')) i.setAttribute('src', i.src);
i.removeAttribute('srcset');
i.removeAttribute('sizes');
i.removeAttribute('loading');
});
c.querySelectorAll('source').forEach(s => s.remove());
c.querySelectorAll('a[href]').forEach(a => {
if (/^[¶#§🔗]?$/.test(a.textContent.trim()) && !a.querySelector('img')) a.remove();
else a.setAttribute('href', a.href);
});
c.querySelectorAll('canvas').forEach(e => e.remove());
return c.innerHTML;
}).join('\n');

// the next page: rel=next, or a link that says "Weiter", "Nächste", "Next", "»" …
const WORD = /^\s*(weiter|nächste|naechste|next|suivant|avanti|continue)\b|[›»→]\s*$/i;
const HINT = /(^|[\s_-])(next|weiter|naechste|nächste)([\s_-]|$)/i;
const nextOf = (doc, url, seen) => {
const ok = h => {
try {
const u = new URL(h, doc.baseURI || url);
if (!/^https?:$/.test(u.protocol) || u.origin !== location.origin) return null;
const v = clean(u.href);
return v === clean(url) || seen.has(v) ? null : v;
} catch (e) { return null; }
};
const rel = doc.querySelector('link[rel~=next][href],a[rel~=next][href]');
if (rel && ok(rel.getAttribute('href'))) return ok(rel.getAttribute('href'));
for (const a of doc.querySelectorAll('a[href]')) {
const cls = typeof a.className === 'string' ? a.className : '';
const label = [a.getAttribute('aria-label'), a.getAttribute('title'), cls, a.id].join(' ');
if ((HINT.test(label) || WORD.test(a.textContent)) && ok(a.getAttribute('href'))) return ok(a.getAttribute('href'));
}
return null;
};

// a page with the whole book, like mdBook's print.html ("Print this book")
const printLink = [...document.querySelectorAll('a[href]')].find(a => a.origin === location.origin
&& (/(^|\/)print\.html$/.test(a.pathname) || /print this book|ganzes buch drucken/i.test((a.title || '') + ' ' + (a.getAttribute('aria-label') || ''))));
let title = document.title, parts = [];
try {
const moodle = location.pathname.match(/^(.*)\/mod\/book\/(view\.php|tool\/print\/index\.php)$/);
const id = new URLSearchParams(location.search).get('id');
if (moodle && id) {
say('Moodle-Buch …');
const d = moodle[2] === 'view.php' ? await fetchDoc(location.origin + moodle[1] + '/mod/book/tool/print/index.php?id=' + id) : document;
title = d.title || title;
parts.push(html(d, ['.book_summary, .book_chapter', '[role=main]', '#region-main']));
} else if (printLink) {
say('Ganzes Buch …');
const d = await fetchDoc(printLink.href);
title = d.title || title;
parts.push(html(d));
} else {
const seen = new Set([clean(location.href)]);
let doc = document, url = location.href;
parts.push(html(document));
while (parts.length < MAX && !stop) {
const next = nextOf(doc, url, seen);
if (!next) break;
seen.add(next);
say('Seite ' + (parts.length + 1) + ' …');
let d = await fetchDoc(next), body = html(d);
if (body.replace(/<[^>]*>/g, '').trim().length < 100) {
const [fd, frame] = await frameDoc(next);
if (fd) { d = fd; body = html(fd); }
frame.remove();
}
parts.push(body);
doc = d;
url = next;
await sleep(150);
}
}
} catch (e) {
say('Fehler: ' + e.message + ' – drucke, was da ist');
await sleep(1500);
}
if (stop) return;

const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const css = 'body{font:15px/1.6 -apple-system,"Segoe UI",system-ui,sans-serif;color:#111;background:#fff;max-width:780px;margin:0 auto;padding:28px}'
+ 'img,svg,video{max-width:100%;height:auto}pre{white-space:pre-wrap;word-break:break-word;background:#f4f4f4;padding:10px;border-radius:6px}'
+ 'code{font-family:ui-monospace,Menlo,monospace;font-size:.92em}table{border-collapse:collapse;max-width:100%}td,th{border:1px solid #ccc;padding:4px 7px;vertical-align:top}'
+ '.buch-pdf-page+.buch-pdf-page{border-top:1px solid #ddd;margin-top:30px;padding-top:14px}a{color:inherit}'
+ '@page{margin:16mm}@media print{body{padding:0;max-width:none}h1,h2,h3,h4{break-after:avoid}img,pre,table,figure{break-inside:avoid}}';
const n = parts.length, lang = document.documentElement.lang || 'de';
document.open();
document.write('<!doctype html><html lang="' + esc(lang) + '"><head><meta charset="utf-8"><title>' + esc(title) + '</title><style>' + css + '</style></head><body>'
+ parts.map(p => '<div class="buch-pdf-page">' + p + '</div>').join('\n') + '</body></html>');
document.close();
await Promise.all([...document.images].map(i => i.complete ? 0 : new Promise(r => { i.onload = i.onerror = r; setTimeout(r, 10000); })));
window.__buchPdf = 0;
window.__buchPdfPages = n;
setTimeout(() => print(), 300);
})();
