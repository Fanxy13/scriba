// Book → PDF – a bookmarklet of Scriba: a book made of web pages becomes one page, then the browser's "Print"
// opens – "Save as PDF" there. Moodle books: their own print view · mdBook and others with "Print this book": that page ·
// OneNote for the web: opened on its own by the first click, then every section and page · Word, PowerPoint, Excel on
// OneDrive or SharePoint: the file itself · otherwise page after page along "Next", "Weiter" or rel=next (same site
// only, at most 500 pages). Protected e-book readers stay as they are.
// docs/index.html turns this file into the bookmark: full-line comments go, the rest is the code.
void (async () => {
if (window.__buchPdf) return;
window.__buchPdf = 1;
const MAX = window.__buchPdfMax || 500;
const box = document.createElement('div');
box.id = 'buch-pdf-box';
box.style.cssText = 'all:initial;position:fixed;z-index:2147483647;top:16px;right:16px;max-width:380px;display:flex;gap:12px;align-items:center;padding:12px 16px;border-radius:14px;background:#0b0f12;color:#eef2ee;font:14px/1.4 -apple-system,system-ui,sans-serif;box-shadow:0 10px 40px rgba(0,0,0,.35)';
box.innerHTML = '<b style="color:#f8b8d0;font-weight:600;white-space:nowrap">Book → PDF</b><span>…</span><button title="Cancel" style="all:unset;cursor:pointer;opacity:.6;padding:0 2px">✕</button>';
let stop = false;
const say = t => { box.children[1].textContent = t; };
box.children[2].onclick = () => { stop = true; box.remove(); window.__buchPdf = 0; };
document.body.appendChild(box);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
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

// the content of a page, without navigation, menus, buttons and the links to the page before and after → HTML
const PAGER = /^([‹«←❮◀]\s*)?(zurück|vorherige?s?|previous|prev|back|weiter|nächste?s?|naechste|next|suivant|précédent|avanti|indietro)(?=$|\s|[›»→❯:])|^[‹«←❮›»→❯▶◀]+$/i;
const JUNK = /(^|[\s_-])(nav|navbar|navigation|menu|sidebar|breadcrumbs?|footer|cookie|banner|toolbar|pagination|share|skip)([\s_-]|$)/i;
const pick = (doc, sel) => {
for (const s of sel || ['.book_content', 'main article', 'article', 'main', '[role=main]', '#region-main', '#content', '.content', '#main']) {
const all = [...doc.querySelectorAll(s)];
if (all.length && all.reduce((n, e) => n + e.textContent.trim().length, 0) > 200) return all;
}
return [doc.body];
};
const isPdf = e => { const s = e.getAttribute('src') || e.getAttribute('data') || ''; return s && (/\.pdf([?#]|$)/i.test(s) || /pdf/i.test(e.getAttribute('type') || '')); };
// what is left of a page's content for paper: no navigation, buttons, site colors or links to the page before and after
const tidy = (c, base) => {
// a PDF shown in the page prints as an empty box: a link to it instead
c.querySelectorAll('iframe,embed,object').forEach(e => {
if (!isPdf(e)) return;
const u = new URL(e.getAttribute('src') || e.getAttribute('data'), base);
const p = document.createElement('p');
const a = document.createElement('a');
a.href = u.href;
a.textContent = 'PDF: ' + decodeURIComponent(u.pathname.split('/').pop() || u.href);
p.append('📄 ', a);
e.replaceWith(p);
});
c.querySelectorAll('script,style,noscript,template,nav,aside,form,button,iframe,embed,object,dialog,#buch-pdf-box,[role=navigation],[role=banner],[role=contentinfo]').forEach(e => e.remove());
// custom elements of the site would build themselves again on the printed page: plain blocks instead
[...c.querySelectorAll('*')].filter(e => e.tagName.includes('-')).forEach(e => { const d = document.createElement('div'); d.append(...e.childNodes); e.replaceWith(d); });
// colors, sizes and positions of the site would make text white, cut or stacked on paper
c.querySelectorAll('[style]').forEach(e => {
for (const p of ['color', 'background', 'background-color', 'background-image', 'opacity', 'filter', '-webkit-text-fill-color', 'mix-blend-mode', 'position', 'top', 'left', 'right', 'bottom', 'transform', 'z-index', 'height', 'max-height', 'overflow', 'overflow-y', 'columns', 'column-count']) e.style.removeProperty(p);
});
c.querySelectorAll('[class],[id]').forEach(e => {
if (JUNK.test((e.className && e.className.baseVal === undefined ? e.className : '') + ' ' + e.id) && e.textContent.trim().length < 400) e.remove();
});
c.querySelectorAll('img').forEach(i => {
const lazy = i.getAttribute('data-src') || i.getAttribute('data-lazy-src') || i.getAttribute('data-original');
if (lazy) i.setAttribute('src', new URL(lazy, base).href);
else if (i.getAttribute('src')) i.setAttribute('src', i.src);
i.removeAttribute('srcset');
i.removeAttribute('sizes');
i.removeAttribute('loading');
});
c.querySelectorAll('source').forEach(s => s.remove());
c.querySelectorAll('a[href]').forEach(a => {
const t = a.textContent.trim();
if ((/^[¶#§🔗]?$/.test(t) && !a.querySelector('img')) || (t.length < 40 && PAGER.test(t))) a.remove();
else a.setAttribute('href', a.href);
});
c.querySelectorAll('canvas').forEach(e => e.remove());
};
const html = (doc, sel, depth = 0) => pick(doc, sel).map(root => {
const c = root.cloneNode(true);
// what frames of the same site and shadow DOM show goes into the copy, before anything is taken out
const orig = [root, ...root.querySelectorAll('*')], copy = [c, ...c.querySelectorAll('*')];
orig.forEach((e, i) => {
const k = copy[i];
if (!k) return;
if (e.tagName === 'IFRAME' && depth < 2 && !isPdf(e)) {
let d = null;
try { d = e.contentDocument; } catch (err) {}
if (d && d.body && d.body.textContent.trim().length > 40) { const div = document.createElement('div'); div.innerHTML = html(d, null, depth + 1); k.replaceWith(div); }
} else if (e.shadowRoot && e.shadowRoot.textContent.trim().length > e.textContent.trim().length) {
k.innerHTML = e.shadowRoot.innerHTML;
}
});
tidy(c, doc.baseURI);
return c.innerHTML;
}).join('\n');

// the next page: rel=next, or a link that says "Weiter", "Nächste", "Next", "»" …
const WORD = /^\s*(weiter|nächste|naechste|next|suivant|avanti|continue)(?=$|\s|[›»→❯:])|[›»→❯]\s*$/i;
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
// nothing to put together: say why instead of printing an empty page
const explain = why => {
const msg = box.children[1];
msg.textContent = why;
msg.style.cssText = 'all:initial;font:inherit;color:inherit;display:block';
pdfs().slice(0, 3).forEach(u => {
const a = document.createElement('a');
a.href = u;
a.target = '_blank';
a.textContent = 'Open the PDF ↗';
a.style.cssText = 'all:initial;font:inherit;display:block;margin-top:6px;color:#b5d371;cursor:pointer;text-decoration:underline';
msg.append(a);
});
window.__buchPdf = 0;
window.__buchPdfInfo = why;
};
const pdfs = () => {
const list = [];
if (document.contentType === 'application/pdf') list.push(location.href);
if (window.PDFViewerApplication && window.PDFViewerApplication.url) list.push(new URL(window.PDFViewerApplication.url, location.href).href);
document.querySelectorAll('iframe,embed,object').forEach(e => { if (isPdf(e)) list.push(new URL(e.getAttribute('src') || e.getAttribute('data'), location.href).href); });
return [...new Set(list)];
};
const drawn = () => [...document.querySelectorAll('canvas')].some(c => c.offsetWidth * c.offsetHeight > 150000)
|| [...document.querySelectorAll('iframe')].some(f => { let d = null; try { d = f.contentDocument; } catch (e) {} return !d && f.offsetWidth * f.offsetHeight > 150000; });
if (/(^|\.)fanxy13\.github\.io$/.test(location.hostname) && location.pathname.startsWith('/scriba')) {
explain('Open a book first – then click the bookmark there.');
return;
}
// OneDrive and SharePoint start Office for the web in a frame of officeapps.live.com with the form office_form – a
// bookmark cannot look into that frame. OneNote: the same form, sent into the whole tab, runs OneNote on its own,
// and the next click reads it. Word, PowerPoint, Excel, a PDF: the file itself, the way OneDrive's Download gets it.
const office = document.forms.office_form && /officeapps/i.test(document.forms.office_form.action) ? document.forms.office_form : null;
if (office) {
const field = n => (office.elements[n] && office.elements[n].value) || '';
const ext = field('fileExtension').toLowerCase(), name = field('fileName') || document.title;
if (/onenote/i.test(office.action) || /^one/.test(ext)) {
explain('Opening OneNote on its own … when it is there, click Book → PDF once more.');
window.__buchPdfInfo = 'onenote-open';
setTimeout(() => { office.target = '_self'; office.submit(); }, 1800);
return;
}
if (field('fileGetUrl')) {
const a = document.createElement('a');
a.href = field('fileGetUrl');
document.body.appendChild(a);
a.click();
a.remove();
explain(ext === 'pdf' ? 'Downloading “' + name + '”.' : 'Downloading “' + name + '” – Scriba reads it as it is. As a PDF: File → Save as → Download as PDF.');
return;
}
}
// elsewhere (Teams, a page that embeds it) the frame stays closed to a bookmark
const oneNoteFrame = [...document.querySelectorAll('iframe')].some(f => /onenote|wopiframe|officeapps/i.test(f.src || '') && !/officeapps\.live\.com$/i.test(location.hostname));
if (oneNoteFrame) {
explain('OneNote runs in a frame here that a bookmark can’t open. Open the notebook in its own browser tab (in Teams: ⋯ → Open in browser) and click Book → PDF there.');
return;
}
if (document.contentType === 'application/pdf' || window.PDFViewerApplication) {
explain('This is a PDF already – open it and save it (⌘S).');
return;
}
// OneNote for the web on its own in the tab: every section and every page, clicked through like a person would
const inOneNote = document.getElementById('NavPaneSectionList') && document.getElementById('WACViewPanel');
const oneNote = async () => {
const out = [];
const items = id => [...document.querySelectorAll('#' + id + ' [role=treeitem]')];
const name = e => (e.innerText || e.textContent || '').trim().split('\n')[0].trim();
const view = () => document.getElementById('WACViewPanel_EditingElement') || document.getElementById('WACViewPanel');
// until nothing changes for a moment: OneNote builds a page in steps
const quiet = async (get, ms = 900) => {
let last = '', same = 0;
for (let i = 0; i < 100 && same * 150 < ms && !stop; i++) {
await sleep(150);
const e = get(), now = e ? e.innerHTML.length + ':' + e.querySelectorAll('img').length : '';
same = now === last ? same + 1 : 0;
last = now;
}
};
// a page as HTML: ink (canvas) and pictures that only live in this tab (blob:, this site) as data
const page = async (el, where) => {
const c = el.cloneNode(true);
const drawn = [...el.querySelectorAll('canvas')], copies = [...c.querySelectorAll('canvas')];
drawn.forEach((cv, i) => { try { const img = document.createElement('img'); img.src = cv.toDataURL(); copies[i].replaceWith(img); } catch (e) {} });
for (const img of c.querySelectorAll('img')) {
const src = img.getAttribute('src') || '';
if (!/^blob:|^\/(?!\/)/.test(src) && !src.startsWith(location.origin)) continue;
try {
const b = await (await fetch(new URL(src, location.href), { credentials: 'include' })).blob();
img.src = await new Promise(r => { const f = new FileReader(); f.onload = () => r(f.result); f.readAsDataURL(b); });
} catch (e) {}
}
c.querySelectorAll('[contenteditable]').forEach(e => e.removeAttribute('contenteditable'));
tidy(c, location.href);
return '<p class="buch-pdf-where">' + esc(where) + '</p>' + c.innerHTML;
};
const done = new Set();
for (let round = 0; round < 500 && !stop; round++) {
const sec = items('NavPaneSectionList').find(e => !done.has(name(e) + '|' + (e.getAttribute('aria-level') || '')));
if (!sec) break;
const secName = name(sec);
done.add(secName + '|' + (sec.getAttribute('aria-level') || ''));
say('Section ' + done.size + ' · ' + secName);
const before = items('PageList').map(name).join('|');
sec.click();
await quiet(() => document.getElementById('PageList'));
// a section group only opens and shows its sections: they come in the next rounds
if (round > 0 && sec.hasAttribute('aria-expanded') && items('PageList').map(name).join('|') === before) continue;
const n = items('PageList').length;
for (let p = 0; p < n && !stop; p++) {
const it = items('PageList')[p];
if (!it) break;
const was = view() ? view().textContent : '';
it.click();
for (let t = 0; t < 60 && view() && view().textContent === was && !stop; t++) await sleep(150);
await quiet(view);
say('Section ' + done.size + ' · page ' + (p + 1) + ' / ' + n);
if (view()) out.push(await page(view(), secName + ' › ' + name(it)));
}
}
return out;
};
let title = document.title, parts = [], breaks = false;
try {
const moodle = location.pathname.match(/^(.*)\/mod\/book\/(view\.php|tool\/print\/index\.php)$/);
const id = new URLSearchParams(location.search).get('id');
if (inOneNote) {
const head = document.getElementById('AppHeaderPanel');
title = (head && head.innerText.trim().split('\n')[0]) || title;
parts = await oneNote();
breaks = true;
if (!parts.length && !stop) { explain('No pages found in this notebook.'); return; }
} else if (moodle && id) {
say('Moodle book …');
const d = moodle[2] === 'view.php' ? await fetchDoc(location.origin + moodle[1] + '/mod/book/tool/print/index.php?id=' + id) : document;
title = d.title || title;
parts.push(html(d, ['.book_summary, .book_chapter', '[role=main]', '#region-main']));
} else if (printLink) {
say('Whole book …');
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
say('Page ' + (parts.length + 1) + ' …');
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
say('Error: ' + e.message + ' – printing what is there');
await sleep(1500);
}
if (stop) return;
const probe = new DOMParser().parseFromString(parts.join(''), 'text/html').body;
if (probe.textContent.replace(/\s+/g, '').length + 200 * probe.querySelectorAll('img,svg,math,table,pre').length < 80) {
if (pdfs().length) explain('The book here is a PDF already:');
else if (drawn()) explain('This reader shows the book as pictures, not as text – Book → PDF can’t save it.');
else explain('No text found on this page.');
return;
}
const css = 'body{font:15px/1.6 -apple-system,"Segoe UI",system-ui,sans-serif;color:#111;background:#fff;max-width:780px;margin:0 auto;padding:28px}'
+ 'img,svg,video{max-width:100%;height:auto}pre{white-space:pre-wrap;word-break:break-word;background:#f4f4f4;padding:10px;border-radius:6px}'
+ 'code{font-family:ui-monospace,Menlo,monospace;font-size:.92em}table{border-collapse:collapse;max-width:100%}td,th{border:1px solid #ccc;padding:4px 7px;vertical-align:top}'
+ '.buch-pdf-page+.buch-pdf-page{border-top:1px solid #ddd;margin-top:30px;padding-top:14px}a{color:inherit}'
+ '.buch-pdf-where{font-size:12px;color:#777;margin:0 0 10px}'
+ (breaks ? '.buch-pdf-page+.buch-pdf-page{break-before:page;border-top:0;margin-top:0;padding-top:0}' : '')
+ '@page{margin:16mm}@media print{body{padding:0;max-width:none}h1,h2,h3,h4{break-after:avoid}img,pre,table,figure{break-inside:avoid}}';
const n = parts.length, lang = document.documentElement.lang || 'en';
document.open();
document.write('<!doctype html><html lang="' + esc(lang) + '"><head><meta charset="utf-8"><title>' + esc(title) + '</title><style>' + css + '</style></head><body>'
+ parts.map(p => '<div class="buch-pdf-page">' + p + '</div>').join('\n') + '</body></html>');
document.close();
await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
await Promise.all([...document.images].map(i => i.complete ? 0 : new Promise(r => { i.onload = i.onerror = r; setTimeout(r, 10000); })));
window.__buchPdf = 0;
window.__buchPdfPages = n;
setTimeout(() => print(), 300);
})();
