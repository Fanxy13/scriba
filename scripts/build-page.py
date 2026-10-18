#!/usr/bin/env python3
"""Writes the bookmark into docs/index.html: the code of docs/book-pdf.js without its full-line comments, as a
javascript: link – so the button works the moment the page is there. Run it after every change of book-pdf.js."""
import re
import urllib.parse
from pathlib import Path

root = Path(__file__).resolve().parent.parent
src = (root / 'docs/book-pdf.js').read_text()
code = '\n'.join(l for l in src.split('\n') if l.strip() and not l.strip().startswith('//'))
href = 'javascript:' + urllib.parse.quote(code, safe="-_.!~*'()")      # like encodeURIComponent
page = root / 'docs/index.html'
html = page.read_text()
new, n = re.subn(r'(<a class="grab" id="grab" href=")[^"]*(")', lambda m: m.group(1) + href + m.group(2), html)
assert n == 1, 'the button was not found in docs/index.html'
page.write_text(new)
print(f'bookmark: {len(code)} characters of code, {len(href)} in the link')
