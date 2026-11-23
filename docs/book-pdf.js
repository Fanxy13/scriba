// Book → PDF – a bookmarklet of Scriba: a book made of web pages becomes one page, then the browser's "Print"
// opens – "Save as PDF" there. Moodle books: their own print view · mdBook and others with "Print this book": that page ·
// OneNote for the web: opened on its own by the first click, then the sections and pages you tick · Word, PowerPoint, Excel on
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
// a formula (MathML, like OneNote and many sites write them) as text a person and Scriba can read: a^(m + n), (a^m)/(a^n)
const mathText = m => {
const k = [...m.children], one = e => mathText(e);
const wrap = s => /^[\p{L}\p{N}.,]+$/u.test(s) || /^\(.*\)$/.test(s) && !/\)\s*\S.*\(/.test(s.slice(1, -1)) ? s : '(' + s + ')';
switch (m.localName) {
case 'mi': case 'mn': case 'mtext': case 'ms': return m.textContent.trim();
case 'mo': { const t = m.textContent.trim(); return /^[=+−\-⋅·×÷<>≤≥≈≠:|]$/.test(t) ? ' ' + t + ' ' : t; }
case 'mspace': return ' ';
case 'msup': return wrap(one(k[0])) + '^' + wrap(one(k[1]));
case 'msub': return wrap(one(k[0])) + '_' + wrap(one(k[1]));
case 'msubsup': return wrap(one(k[0])) + '_' + wrap(one(k[1])) + '^' + wrap(one(k[2]));
case 'mfrac': return wrap(one(k[0])) + '/' + wrap(one(k[1]));
case 'msqrt': return '√' + wrap(k.map(one).join(''));
case 'mroot': return one(k[1]) + '√' + wrap(one(k[0]));
case 'munder': return one(k[0]) + '_' + wrap(one(k[1]));
case 'mover': return one(k[0]) + '^' + wrap(one(k[1]));
case 'munderover': return one(k[0]) + '_' + wrap(one(k[1])) + '^' + wrap(one(k[2]));
case 'mtable': return k.map(one).join('; ');
case 'mtr': return k.map(one).join(', ');
case 'annotation': case 'annotation-xml': return '';
default: return k.length ? k.map(one).join('') : m.textContent.trim();
}
};
// what is left of a page's content for paper: no navigation, buttons, site colors or links to the page before and after
const tidy = (c, base) => {
// formulas as text: a printed formula loses its exponents when the PDF is read (2^3 would become 23)
c.querySelectorAll('.RawEquation,.EquationPlaceholderText').forEach(e => e.remove());
c.querySelectorAll('math').forEach(m => {
const tex = m.querySelector('annotation[encoding*="tex"]');
const t = tex ? '$' + tex.textContent.trim() + '$' : mathText(m).replace(/\s+/g, ' ').trim();
const e = document.createElement(m.getAttribute('display') === 'block' ? 'div' : 'span');
e.textContent = t;
m.replaceWith(e);
});
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
// OneNote for the web on its own in the tab. It asks what to save – any groups, sections and single pages, ticked in a
// tree – then clicks through every one of them like a person would. Pictures of printouts (a Word file or PDF put
// into OneNote) load only when they are in view: it scrolls to each one first.
const inOneNote = document.getElementById('NavPaneSectionList') && document.getElementById('WACViewPanel');
const opts = { pics: true, sheets: true };
let named = '';
const oneNote = async () => {
const out = [];
const T = e => (e.innerText || e.textContent || '').trim().split('\n')[0].trim();
const sections = () => [...document.querySelectorAll('#NavPaneSectionList [role=treeitem]')];
const isGroup = e => e.hasAttribute('aria-expanded') || /section group|abschnittsgruppe/i.test(e.getAttribute('aria-label') || '');
// the sections of a group sit in a [role=group] right after the group's own entry (or inside it)
const parentOf = e => {
const g = e.parentElement && e.parentElement.closest('[role=group]');
if (g && g.closest('#NavPaneSectionList')) {
const before = g.previousElementSibling;
if (before && before.matches('[role=treeitem]')) return before;
const around = g.parentElement && g.parentElement.closest('[role=treeitem]');
if (around) return around;
}
return e.parentElement && e.parentElement.closest('[role=treeitem]');
};
const pathOf = e => { const n = []; for (let x = e; x; x = parentOf(x)) n.unshift(T(x)); return n.join(' › '); };
const byPath = p => sections().find(e => pathOf(e) === p);
const pages = () => { const n = [...document.querySelectorAll('#PageList .pageNode')]; return n.length ? n : [...document.querySelectorAll('#PageList [role=treeitem]')]; };
const view = () => document.getElementById('PageContentContainer') || document.getElementById('WACViewPanel');
const titleNow = () => { const t = document.querySelector('#PageContentContainer .Title'); return t ? t.innerText.trim() : ''; };
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
// what to save: the notebook as a tree with a box at every group, section and page. Groups are opened first; the pages
// of a section are read when its "pages" is opened. The content library is ticked to begin with (else everything).
const opened = new Set();
for (let round = 0; round < 8 && !stop; round++) {
const closed = sections().filter(e => isGroup(e) && e.getAttribute('aria-expanded') !== 'true' && !opened.has(pathOf(e))).map(pathOf);
if (!closed.length) break;
for (const p of closed) {
opened.add(p);
const e = byPath(p);
if (e) { e.click(); await quiet(() => document.getElementById('NavPaneSectionList')); }
}
}
const depthOf = e => { let d = 0; for (let x = parentOf(e); x; x = parentOf(x)) d++; return d; };
const nodes = sections().map(e => ({ path: pathOf(e), label: T(e), depth: depthOf(e), group: isGroup(e), on: false, pages: null, open: false }));
if (!nodes.length) return out;
const leaves = n => nodes.filter(m => !m.group && m.path.startsWith(n.path + ' › '));
// 1 = all of it, .5 = a part, 0 = nothing
const state = n => {
if (n.group) { const l = leaves(n).map(state); return l.length && l.every(s => s === 1) ? 1 : l.some(s => s) ? .5 : 0; }
if (n.pages) { const k = n.pages.filter(p => p.on).length; return k && k === n.pages.length ? 1 : k ? .5 : 0; }
return n.on ? 1 : 0;
};
const setSec = (n, v) => { n.on = v; if (n.pages) n.pages.forEach(p => { p.on = v; }); };
const lib = nodes.find(n => !n.depth && /inhaltsbibliothek|content library|bibliothèque|biblioteca/i.test(n.label));
for (const n of nodes) if (!n.group && (!lib || n === lib || n.path.startsWith(lib.path + ' › '))) setSec(n, true);
const el = (tag, css, text) => {
const e = document.createElement(tag);
e.style.cssText = 'all:initial;font:inherit;color:inherit;display:block;' + css;
if (text != null) e.textContent = text;
return e;
};
const btn = (text, css, fn) => { const b = el('button', 'cursor:pointer;' + css, text); b.onclick = fn; return b; };
const PINK = '#f8b8d0', GREY = '#8b979d', FIELD = 'background:#1d2428;border-radius:8px;padding:5px 9px;';
const picked = await new Promise(done => {
const msg = box.children[1], was = box.style.cssText;
msg.textContent = '';
box.style.cssText = was + ';width:min(480px,calc(100vw - 32px));max-width:none;box-sizing:border-box;align-items:flex-start;max-height:calc(100vh - 32px)';
msg.style.cssText = 'all:initial;font:inherit;color:inherit;display:flex;flex-direction:column;gap:9px;flex:1;min-width:0';
const find = el('input', 'flex:1;min-width:0;font-size:13px;border:1px solid #2c363b;' + FIELD);
find.placeholder = 'Search …';
['keydown', 'keyup', 'keypress'].forEach(t => find.addEventListener(t, e => e.stopPropagation()));
const shown = n => {
const f = find.value.trim().toLowerCase();
return !f || nodes.some(m => m.path.toLowerCase().includes(f) && (m.path === n.path || m.path.startsWith(n.path + ' › ')));
};
const all = v => { nodes.filter(n => !n.group && shown(n)).forEach(n => setSec(n, v)); render(); };
const bar = el('div', 'display:flex;gap:6px;align-items:center');
bar.append(find, btn('All', FIELD, () => all(true)), btn('None', FIELD, () => all(false)));
const list = el('div', 'overflow:auto;max-height:min(46vh,360px);padding-right:4px');
const extra = el('div', 'border-top:1px solid #2c363b;padding-top:6px');
const info = el('span', 'flex:1;font-size:13px;opacity:.75');
const go = btn('Save as PDF', 'padding:7px 13px;border-radius:9px;font-weight:600;background:' + PINK + ';color:#111', () => { const p = nodes.filter(n => !n.group && state(n)); if (p.length) done(p); });
const foot = el('div', 'display:flex;gap:10px;align-items:center');
foot.append(info, go);
msg.append(el('div', 'font-weight:600', 'What should I save?'), bar, list, extra, foot);
const line = (indent, s, label, fn, bold) => {
const row = el('div', 'display:flex;align-items:center;gap:6px;padding:3px 0 3px ' + indent + 'px');
row.append(btn(s === 1 ? '☑' : s ? '▣' : '☐', 'width:18px;flex:none;color:' + (s ? PINK : GREY), fn));
row.append(btn(label, 'flex:1;min-width:0;text-align:left;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;' + (bold ? 'font-weight:600' : ''), fn));
row.lastChild.title = label;
return row;
};
let busy = false;
const expand = async n => {
if (busy) return;
if (n.open) { n.open = false; render(); return; }
if (!n.pages) {
busy = true;
info.textContent = 'Reading the pages …';
const sec = byPath(n.path);
if (sec) {
sec.click();
await quiet(() => document.getElementById('PageList'));
const got = pages().map(it => ({ t: T(it), on: n.on }));
if (got.length) n.pages = got;
}
busy = false;
}
n.open = !!n.pages;
render();
};
const render = () => {
const y = list.scrollTop;
list.textContent = '';
for (const n of nodes) {
if (!shown(n)) continue;
const fn = () => { const v = state(n) !== 1; (n.group ? leaves(n) : [n]).forEach(l => setSec(l, v)); render(); };
const row = line(n.depth * 16, state(n), n.label || '…', fn, n.group);
if (!n.group) row.append(btn((n.open ? '▾' : '▸') + ' pages', 'flex:none;font-size:12px;opacity:.65', () => expand(n)));
list.append(row);
if (n.open && n.pages) n.pages.forEach(p => list.append(line(n.depth * 16 + 24, p.on ? 1 : 0, p.t || 'Untitled', () => { p.on = !p.on; n.on = n.pages.some(q => q.on); render(); })));
}
list.scrollTop = y;
extra.textContent = '';
[['pics', 'Pictures and printouts'], ['sheets', 'Every page on a new sheet']].forEach(([k, label]) => extra.append(line(0, opts[k] ? 1 : 0, label, () => { opts[k] = !opts[k]; render(); })));
const on = nodes.filter(n => !n.group && state(n));
const pg = on.every(n => n.pages) ? ' · ' + on.reduce((s, n) => s + n.pages.filter(p => p.on).length, 0) + ' pages' : '';
info.textContent = on.length + (on.length === 1 ? ' section' : ' sections') + pg;
go.style.opacity = on.length ? '1' : '.4';
};
find.oninput = render;
render();
const close = box.children[2].onclick;
box.children[2].onclick = () => { close(); done(null); };
box.restore = () => { box.style.cssText = was; msg.style.cssText = ''; msg.textContent = '…'; };
});
if (!picked) { stop = true; return out; }
box.restore();
const tops = [...new Set(picked.map(n => n.path.split(' › ')[0]))];
named = picked.length === 1 ? picked[0].label : tops.length === 1 ? tops[0] : '';
window.__buchPdfChoice = picked.map(n => n.path);
const jobs = picked.map(n => ({ path: n.path, only: n.pages && n.pages.some(p => !p.on) ? n.pages.map(p => p.on) : null }));
for (let s = 0; s < jobs.length && !stop; s++) {
const sec = byPath(jobs[s].path);
if (!sec) continue;
say('Section ' + (s + 1) + ' / ' + jobs.length + ' · ' + T(sec));
sec.click();
await quiet(() => document.getElementById('PageList'));
const n = pages().length;
const want = jobs[s].only && jobs[s].only.length === n ? jobs[s].only : null;
const total = want ? want.filter(Boolean).length : n;
let k = 0;
for (let p = 0; p < n && !stop; p++) {
if (want && !want[p]) continue;
const it = pages()[p];
if (!it) break;
const was = titleNow();
(it.querySelector('[role=button]') || it).click();
for (let t = 0; t < 40 && titleNow() === was && !stop; t++) await sleep(150);
await quiet(view);
say('Section ' + (s + 1) + ' / ' + jobs.length + ' · page ' + (++k) + ' / ' + total);
// printouts: scroll to each picture until it is there
const v = view();
if (!v) continue;
for (const img of opts.pics ? [...v.querySelectorAll('img')] : []) {
if (img.closest('.OutlineResizeHandleContainer') || (img.complete && img.naturalWidth)) continue;
(img.closest('.WACImageContainer') || img).scrollIntoView({ block: 'center' });
for (let t = 0; t < 40 && !(img.complete && img.naturalWidth) && !stop; t++) await sleep(150);
}
out.push(await page(v, T(sec) + ' › ' + (titleNow().split('\n')[0] || T(it))));
}
}
return out;
};
// a OneNote page as HTML: pictures as data (blob: lives only in this tab), no OneNote handles, icons and sizes
const page = async (el, where) => {
const c = el.cloneNode(true);
const orig = [...el.querySelectorAll('img')], copies = [...c.querySelectorAll('img')];
for (let i = 0; i < copies.length; i++) {
const o = orig[i], k = copies[i], src = k.getAttribute('src') || '';
if (!opts.pics || !src || k.closest('.OutlineResizeHandleContainer') || /onecdn\.static|static\.microsoft/.test(src) || (o && o.naturalWidth && o.naturalWidth < 48)) { k.remove(); continue; }
if (!/^blob:/.test(src)) continue;
try {
const b = await (await fetch(src)).blob();
k.src = await new Promise(r => { const f = new FileReader(); f.onload = () => r(f.result); f.readAsDataURL(b); });
} catch (e) {}
}
c.querySelectorAll('[contenteditable]').forEach(e => e.removeAttribute('contenteditable'));
c.querySelectorAll('[style]').forEach(e => { for (const p of ['width', 'min-width', 'max-width', 'margin-left']) e.style.removeProperty(p); });
tidy(c, location.href);
return '<p class="buch-pdf-where">' + esc(where) + '</p>' + c.innerHTML;
};
let title = document.title, parts = [], breaks = false;
try {
const moodle = location.pathname.match(/^(.*)\/mod\/book\/(view\.php|tool\/print\/index\.php)$/);
const id = new URLSearchParams(location.search).get('id');
if (inOneNote) {
const head = document.getElementById('AppHeaderPanel');
title = (head && head.innerText.trim().split('\n')[0]) || title;
parts = await oneNote();
if (named) title = named.replace(/^_/, '') + ' – ' + title;
breaks = opts.sheets;
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
// own (empty) page margin boxes: Chrome then prints no address, date or page count of its own
+ '@page{margin:16mm;@top-left{content:""}@top-center{content:""}@top-right{content:""}@bottom-left{content:""}@bottom-center{content:""}@bottom-right{content:""}}@media print{body{padding:0;max-width:none}h1,h2,h3,h4{break-after:avoid}img,pre,table,figure{break-inside:avoid}}';
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
