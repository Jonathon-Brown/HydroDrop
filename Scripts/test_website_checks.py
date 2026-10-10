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
    def alter(self,old,new):
        path=self.site/'index.html'; path.write_text(path.read_text().replace(old,new))
    def test_site_passes(self): self.assertEqual(audit(self.site),[])
    def test_csp_regression(self):
        self.alter("script-src 'self'","script-src * 'unsafe-inline'")
        self.assertTrue(any('CSP: script-src' in e for e in audit(self.site)))
    def test_inline_event(self):
        self.alter('<body id="top">','<body id="top" onload="alert(1)">')
        self.assertTrue(any('Inline executable' in e for e in audit(self.site)))
    def test_private_artifact(self):
        (self.site/'.env').write_text('EXAMPLE=placeholder')
        self.assertTrue(any('private/development' in e for e in audit(self.site)))
    def test_dom_sink(self):
        (self.site/'unsafe.js').write_text('target.innerHTML = location.hash;')
        self.assertTrue(any('unsafe DOM sink' in e for e in audit(self.site)))
    def test_broken_link(self):
        self.alter('href="/support.html"','href="/missing.html"')
        self.assertTrue(any('broken link' in e for e in audit(self.site)))
    def test_missing_alt(self):
        self.alter('alt=""','')
        self.assertTrue(any('missing alt' in e for e in audit(self.site)))

if __name__=='__main__': unittest.main()
