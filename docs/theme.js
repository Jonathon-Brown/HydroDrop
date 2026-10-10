// This contains only a local display preference; no visitor data is transmitted.
(() => {
  let saved;
  try { saved = localStorage.getItem('hydrodrop-theme'); } catch { /* Storage may be disabled. */ }
  const preference = matchMedia('(prefers-color-scheme: dark)');
  document.documentElement.dataset.theme = saved === 'light' || saved === 'dark' ? saved : preference.matches ? 'dark' : 'light';
  preference.addEventListener('change', event => {
    let choice;
    try { choice = localStorage.getItem('hydrodrop-theme'); } catch { /* Follow the system. */ }
    if (choice !== 'light' && choice !== 'dark') {
      document.documentElement.dataset.theme = event.matches ? 'dark' : 'light';
      document.dispatchEvent(new Event('themechange'));
    }
  });
})();
