import shutil
import tempfile
import unittest
from pathlib import Path
from check_website import audit

class PublishingChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.site=Path(self.temp.name)/'site'
        shutil.copytree(Path(__file__).resolve().parents[1]/'docs',self.site)
    def tearDown(self): self.temp.cleanup()
    def alter(self,old,new,page='index.html'):
        path=self.site/page; text=path.read_text(); self.assertIn(old,text); path.write_text(text.replace(old,new))
    def failures(self,needle): return [e for e in audit(self.site) if needle in e]
    def test_site_passes(self): self.assertEqual(audit(self.site),[])
    def test_csp_regression(self):
        self.alter("script-src 'self'","script-src * 'unsafe-inline'")
        self.assertTrue(self.failures('CSP: script-src'))
    def test_inline_event(self):
        self.alter('<body id="top">','<body id="top" onload="alert(1)">')
        self.assertTrue(self.failures('Inline executable'))
    def test_private_artifact(self):
        (self.site/'.env').write_text('EXAMPLE=placeholder')
        self.assertTrue(self.failures('private/development'))
    def test_editor_and_backup_artifacts(self):
        (self.site/'.DS_Store').write_bytes(b'\0'); (self.site/'index.html.bak').write_text(''); (self.site/'notes~').write_text('')
        self.assertEqual(len(self.failures('private/development')),3)
    def test_dom_sink(self):
        (self.site/'unsafe.js').write_text('target.innerHTML = location.hash;')
        self.assertTrue(self.failures('unsafe DOM sink'))
    def test_string_timer_and_navigation_sinks(self):
        (self.site/'timer.js').write_text("setTimeout('go()', 1);"); (self.site/'nav.js').write_text('location = q;')
        self.assertEqual(len(self.failures('unsafe DOM sink')),2)
    def test_remote_srcset(self):
        self.alter('<body id="top">','<body id="top"><img alt="" srcset="https://example.invalid/x.png 1x, /icon.png 2x">')
        self.assertTrue(self.failures('Remote executable/resource dependency'))
    def test_meta_refresh(self):
        self.alter('<meta name="referrer" content="no-referrer">','<meta name="referrer" content="no-referrer"><meta http-equiv="refresh" content="0;url=https://example.invalid">')
        self.assertTrue(self.failures('Meta refresh'))
    def test_remote_stylesheet_dependency(self):
        (self.site/'extra.css').write_text("@import url('https://example.invalid/f.css');")
        self.assertTrue(self.failures('remote stylesheet dependency'))
    def test_broken_link(self):
        self.alter('href="/support.html"','href="/missing.html"')
        self.assertTrue(self.failures('broken link'))
    def test_missing_alt(self):
        self.alter('alt=""','')
        self.assertTrue(self.failures('missing alt'))
    def test_association_file_pinned(self):
        self.alter('YR8YP5788W.com.jonathonbrown.HydroDrop','YR8YP5788W.com.example.Other','.well-known/apple-app-site-association')
        self.assertTrue(self.failures('names a different app'))
    def test_association_file_keeps_its_paths(self):
        self.alter('"/duo"','"/other"','.well-known/apple-app-site-association')
        self.assertTrue(self.failures('lost a universal-link path'))
    def test_association_file_must_parse(self):
        (self.site/'.well-known'/'apple-app-site-association').write_text('{')
        self.assertTrue(self.failures('Missing/invalid apple-app-site-association'))
    def test_app_ads_pinned(self):
        self.alter('pub-5814718978331211','pub-0000000000000000','app-ads.txt')
        self.assertTrue(self.failures('app-ads.txt changed'))

if __name__=='__main__': unittest.main()
