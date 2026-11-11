#!/usr/bin/env python3
"""Fail on publishing mistakes in the static website. This is a guardrail, not a penetration test."""
import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit, unquote
import xml.etree.ElementTree as ET

REQUIRED = {
    'default-src': "'none'", 'script-src': "'self'", 'script-src-attr': "'none'",
    'style-src': "'self'", 'style-src-attr': "'none'", 'img-src': "'self'",
    'connect-src': "'none'", 'object-src': "'none'", 'base-uri': "'none'",
    'form-action': "'none'", 'frame-src': "'none'", 'worker-src': "'none'",
}

# Editors and macOS leave these beside the pages they came from, and a backup of a page is a
# second copy of it that nobody reviews.
PRIVATE_SUFFIXES=('.pem','.key','.p8','.p12','.pfx','.map','.log','.bak','.orig','.swp','.sql')
PRIVATE_NAMES=('.DS_Store','.htpasswd','Thumbs.db')
# Attributes that fetch or navigate. srcset carries several candidates, each followed by a
# descriptor, so it is split before each candidate is read as a URL.
URL_ATTRIBUTES=('src','href','srcset','poster','ping','formaction','data')
# Sinks and reads that turn attacker-controlled text into markup, code or a navigation, plus
# the debug artifacts that have no place on the live site. A match means review, not
# necessarily a bug; the site's one validated hash-derived write goes through setAttribute,
# which is deliberately not here.
SINKS=re.compile(
    r'innerHTML|outerHTML|insertAdjacentHTML|srcdoc|document\.write|\beval\s*\(|\bFunction\s*\('
    r'|setTimeout\s*\(\s*["\']|setInterval\s*\(\s*["\']|createContextualFragment'
    r'|\blocation\s*(\.href\s*)?=[^=]|location\.(assign|replace)\s*\(|window\.open\s*\('
    r'|document\.cookie|document\.referrer|window\.name\b|postMessage|sourceMappingURL|\bdebugger\b'
)
# The two files whose corruption breaks something silently: a changed publisher id redirects
# ad revenue, and a changed app id hands bottle taps and invite links to another app. Apple
# caches a failed fetch of the association file, so a syntax error there costs days.
APP_ADS='google.com, pub-5814718978331211, DIRECT, f08c47fec0942fa0'
APP_IDS=['YR8YP5788W.com.jonathonbrown.HydroDrop']

class Page(HTMLParser):
    def __init__(self):
        super().__init__(); self.ids=set(); self.refs=[]; self.errors=[]; self.policy=None
        self.title=False; self.description=False; self.referrer=False; self.resources=False; self.canonical=False
    def handle_starttag(self, tag, attributes):
        a=dict(attributes)
        if 'id' in a:
            if a['id'] in self.ids: self.errors.append('Duplicate ID: '+a['id'])
            self.ids.add(a['id'])
        if tag=='title': self.title=True
        if tag=='meta':
            if a.get('name')=='description': self.description=bool(a.get('content'))
            if a.get('name')=='referrer': self.referrer=a.get('content')=='no-referrer'
            if a.get('http-equiv','').lower()=='content-security-policy':
                if self.resources: self.errors.append('CSP must precede resource loading')
                self.policy=dict((part.strip().split(' ',1)+[''])[:2] for part in a.get('content','').split(';') if part.strip())
            if a.get('http-equiv','').lower()=='refresh': self.errors.append('Meta refresh is forbidden')
        if tag=='link' and a.get('rel')=='canonical': self.canonical=a.get('href','').startswith('https://hydrodrop.us/')
        if tag in ('script','style','img') or (tag=='link' and a.get('rel')=='stylesheet'): self.resources=True
        if tag in ('style','iframe','object','embed','base','form'): self.errors.append('Unexpected active element: '+tag)
        if tag=='script' and not a.get('src'): self.errors.append('Inline script is forbidden')
        if tag=='img' and 'alt' not in a: self.errors.append('Image missing alt text')
        for name,value in attributes:
            if name.startswith('on') or name=='style': self.errors.append('Inline executable/style attribute: '+name)
            if name not in URL_ATTRIBUTES or value is None: continue
            candidates=[part.strip().split(' ')[0] for part in value.split(',')] if name=='srcset' else [value]
            for candidate in candidates:
                normalized=re.sub(r'[\x00-\x20]','',candidate)
                url=urlsplit(normalized)
                if url.scheme in ('javascript','data','vbscript','http'): self.errors.append('Unsafe URL scheme: '+url.scheme)
                resource=name!='href' or (tag=='link' and a.get('rel') in ('stylesheet','preload','preconnect'))
                if resource and (url.scheme or url.netloc): self.errors.append('Remote executable/resource dependency')
                if not url.scheme and not url.netloc: self.refs.append(candidate)

def audit(site):
    errors=[]; pages={}
    for file in site.rglob('*'):
        relative=file.relative_to(site)
        if file.is_symlink(): errors.append(f'{relative}: symlinks cannot be published')
        if not file.is_file(): continue
        if file.name in PRIVATE_NAMES or file.name.endswith('~') or file.name.startswith(('.env','.dev.vars')) or file.suffix in PRIVATE_SUFFIXES or any(part in ('.git','.wrangler','node_modules') for part in relative.parts):
            errors.append(f'{relative}: private/development artifact in publish directory')
        if file.suffix=='.html':
            page=Page(); page.feed(file.read_text()); pages[file.resolve()]=page
            for directive,value in REQUIRED.items():
                if not page.policy or page.policy.get(directive)!=value: page.errors.append('Missing/unsafe CSP: '+directive)
            if not page.referrer: page.errors.append('Missing no-referrer policy')
            if not page.title or not page.description or not page.canonical: page.errors.append('Missing title, description or HTTPS canonical')
            errors.extend(f'{relative}: {error}' for error in page.errors)
        if file.suffix=='.js':
            if SINKS.search(file.read_text()):
                errors.append(f'{relative}: unsafe DOM sink, navigation, cookie write or debug artifact; review required')
        if file.suffix=='.css':
            # The CSP blocks these at runtime; flagged here because they are the same publishing
            # mistake the script check exists for, and a stylesheet that quietly fails to load a
            # font or image is worth knowing about before it ships.
            if re.search(r'@import|url\(\s*["\']?(https?:)?//',file.read_text()):
                errors.append(f'{relative}: remote stylesheet dependency')
    for file,page in pages.items():
        for ref in page.refs:
            url=urlsplit(ref); raw=unquote(url.path)
            target=(site/raw.lstrip('/') if raw.startswith('/') else file.parent/raw) if raw else file
            target=target.resolve()
            if not target.is_relative_to(site.resolve()): errors.append(f'{file.name}: reference escapes website'); continue
            if target.is_dir(): target=target/'index.html'
            if not target.exists(): errors.append(f'{file.name}: broken link/asset {ref}')
            elif url.fragment and target in pages and unquote(url.fragment) not in pages[target].ids:
                errors.append(f'{file.name}: broken fragment {ref}')
    if not (site/'404.html').exists(): errors.append('Missing custom 404')
    try:
        sitemap=ET.parse(site/'sitemap.xml')
        for loc in sitemap.findall('.//{http://www.sitemaps.org/schemas/sitemap/0.9}loc'):
            path=urlsplit(loc.text).path
            target=site/path.lstrip('/') if path!='/' else site/'index.html'
            if not loc.text.startswith('https://hydrodrop.us/') or not target.exists(): errors.append('Invalid sitemap entry')
        if 'Sitemap: https://hydrodrop.us/sitemap.xml' not in (site/'robots.txt').read_text(): errors.append('Missing robots sitemap declaration')
    except (OSError,ET.ParseError): errors.append('Missing/invalid sitemap or robots.txt')
    try:
        association=json.loads((site/'.well-known'/'apple-app-site-association').read_text())
        details=association['applinks']['details']
        if [detail['appIDs'] for detail in details]!=[APP_IDS]: errors.append('apple-app-site-association names a different app')
        paths={component['/'] for detail in details for component in detail['components']}
        if not {'/tap*','/duo'}<=paths: errors.append('apple-app-site-association lost a universal-link path')
    except (OSError,ValueError,KeyError,TypeError): errors.append('Missing/invalid apple-app-site-association')
    try:
        if (site/'app-ads.txt').read_text().strip()!=APP_ADS: errors.append('app-ads.txt changed')
    except OSError: errors.append('Missing app-ads.txt')
    return errors

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--site',type=Path,default=Path(__file__).resolve().parents[1]/'docs')
    args=parser.parse_args(); failures=audit(args.site)
    for failure in failures: print('FAIL:',failure)
    print(f'{len(failures)} failure(s); checked security policy, local references, metadata, the association file, app-ads.txt and publish artifacts.')
    sys.exit(bool(failures))
