// Shared by the banner above and the page script below. Same normalisation as the apps:
  // uppercase, O to 0, I and L to 1, dashes and spaces dropped; the code is the text before the
  // first dot, the secret (if any) is everything after it and is only checked for shape.
  function duoParse(hash) {
    var parts = hash.replace(/^#/, '').split('.');
    var code = parts[0];
    try { code = decodeURIComponent(code); } catch (e) { /* keep it as typed */ }
    code = code.toUpperCase().replace(/O/g, '0').replace(/[IL]/g, '1').replace(/[\s-]/g, '');
    if (!/^[0-9A-HJKMNP-TV-Z]{8}$/.test(code)) { return null; }
    var secret = parts.length > 1 && /^[0-9A-HJKMNP-TV-Z]{26}$/.test(parts[1]) ? parts[1] : '';
    return { code: code, secret: secret };
  }
  function duoBanner() {
    var m = document.getElementById('smart-banner');
    var invite = duoParse(location.hash);
    var link = 'https://hydrodrop.us/duo' + (invite ? '#' + invite.code + (invite.secret ? '.' + invite.secret : '') : '');
    if (m) { m.setAttribute('content', 'app-id=6793399317, app-argument=' + link); }
  }
  duoBanner();
