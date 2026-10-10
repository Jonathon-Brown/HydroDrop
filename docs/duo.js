(function () {
    var codeEl = document.getElementById('code');
    var helpEl = document.getElementById('code-help');
    var noCodeEl = document.getElementById('no-code');
    var copyBtn = document.getElementById('copy');
    var statusEl = document.getElementById('copy-status');
    var storeBtn = document.getElementById('store');
    var display = '';

    function render() {
      // Only the code is ever shown or copied. The secret after the dot goes nowhere but the
      // Smart App Banner's app-argument, and only when it has the right shape.
      var invite = duoParse(location.hash);
      var ok = invite !== null;
      display = ok ? invite.code.slice(0, 4) + '-' + invite.code.slice(4) : '';
      codeEl.textContent = display;
      codeEl.hidden = !ok;
      helpEl.hidden = !ok;
      copyBtn.hidden = !ok;
      noCodeEl.hidden = ok;
      storeBtn.classList.toggle('ghost', ok);
      duoBanner();
    }

    function copied() {
      copyBtn.textContent = 'Copied';
      statusEl.textContent = 'Code copied';
      setTimeout(function () { copyBtn.textContent = 'Copy code'; statusEl.textContent = ''; }, 2000);
    }

    // When a selection is copied, browsers add rich flavours (HTML, web archive, source URL) that
    // carry the page address, fragment and all. This listener replaces the payload with the plain
    // code whenever the copy comes from the button or from a selection inside the code itself, so
    // the secret never reaches the clipboard in any flavour.
    var copying = false;
    document.addEventListener('copy', function (e) {
      var selection = window.getSelection();
      var inCode = selection && selection.anchorNode && codeEl.contains(selection.anchorNode);
      if (!(copying || inCode) || !e.clipboardData) { return; }
      e.clipboardData.setData('text/plain', display);
      e.preventDefault();
    });

    // execCommand only works inside the click, so it runs first and synchronously; the async
    // clipboard API is the fallback. Either way the code is left selected, so a manual copy
    // still works if both fail.
    copyBtn.addEventListener('click', function () {
      var range = document.createRange();
      range.selectNodeContents(codeEl);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      var done = false;
      copying = true;
      try { done = document.execCommand('copy'); } catch (e) { done = false; }
      copying = false;
      if (done) { copied(); return; }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(display).then(copied, function () { statusEl.textContent = 'Copy failed. The code is selected; copy it by hand.'; });
      } else {
        statusEl.textContent = 'Copy failed. The code is selected; copy it by hand.';
      }
    });

    render();
    window.addEventListener('hashchange', render);
  })();
