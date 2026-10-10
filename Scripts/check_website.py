#!/usr/bin/env python3
"""Fail on publishing mistakes in the static website. This is a guardrail, not a penetration test."""
import argparse
from html.parser import HTMLParser
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
        if tag=='link' and a.get('rel')=='canonical': self.canonical=a.get('href','').startswith('https://hydrodrop.us/')
        if tag in ('script','style','img') or (tag=='link' and a.get('rel')=='stylesheet'): self.resources=True
        if tag in ('style','iframe','object','embed','base','form'): self.errors.append('Unexpected active element: '+tag)
        if tag=='script' and not a.get('src'): self.errors.append('Inline script is forbidden')
        if tag=='img' and 'alt' not in a: self.errors.append('Image missing alt text')
        for name,value in attributes:
            if name.startswith('on') or name=='style': self.errors.append('Inline executable/style attribute: '+name)
            if name not in ('src','href') or value is None: continue
            normalized=re.sub(r'[\x00-\x20]','',value)
            url=urlsplit(normalized)
            if url.scheme in ('javascript','data','vbscript','http'): self.errors.append('Unsafe URL scheme: '+url.scheme)
            resource=name=='src' or (tag=='link' and a.get('rel') in ('stylesheet','preload','preconnect'))
            if resource and (url.scheme or url.netloc): self.errors.append('Remote executable/resource dependency')
            if not url.scheme and not url.netloc: self.refs.append(value)

def audit(site):
    errors=[]; pages={}
    for file in site.rglob('*'):
        relative=file.relative_to(site)
        if file.is_symlink(): errors.append(f'{relative}: symlinks cannot be published')
        if not file.is_file(): continue
        if file.name.startswith(('.env','.dev.vars')) or file.suffix in ('.pem','.key','.p8','.p12','.pfx','.map','.log') or any(part in ('.git','.wrangler','node_modules') for part in relative.parts):
            errors.append(f'{relative}: private/development artifact in publish directory')
        if file.suffix=='.html':
            page=Page(); page.feed(file.read_text()); pages[file.resolve()]=page
            for directive,value in REQUIRED.items():
                if not page.policy or page.policy.get(directive)!=value: page.errors.append('Missing/unsafe CSP: '+directive)
            if not page.referrer: page.errors.append('Missing no-referrer policy')
            if not page.title or not page.description or not page.canonical: page.errors.append('Missing title, description or HTTPS canonical')
            errors.extend(f'{relative}: {error}' for error in page.errors)
        if file.suffix=='.js':
            source=file.read_text()
            if re.search(r'innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\s*\(|new\s+Function|document\.cookie|sourceMappingURL|\bdebugger\b',source):
                errors.append(f'{relative}: unsafe DOM sink, cookie write or debug artifact; review required')
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
    return errors

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--site',type=Path,default=Path(__file__).resolve().parents[1]/'docs')
    args=parser.parse_args(); failures=audit(args.site)
    for failure in failures: print('FAIL:',failure)
    print(f'{len(failures)} failure(s); checked security policy, local references, metadata and publish artifacts.')
    sys.exit(bool(failures))
