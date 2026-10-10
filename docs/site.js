(() => {
  const root = document.documentElement;
  const theme = document.querySelector('.theme-toggle');
  const updateThemeLabel = () => { theme.textContent = root.dataset.theme === 'dark' ? 'Light theme' : 'Dark theme'; theme.setAttribute('aria-label', `Switch to ${root.dataset.theme === 'dark' ? 'light' : 'dark'} theme`); };
  theme.hidden = false;
  updateThemeLabel();
  theme.addEventListener('click', () => {
    root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('hydrodrop-theme', root.dataset.theme); } catch { /* The choice still applies to this page. */ }
    updateThemeLabel();
  });
  document.addEventListener('themechange', updateThemeLabel);
  const menu = document.querySelector('.menu-toggle');
  const nav = document.getElementById('site-navigation');
  const closeMenu = () => { menu.setAttribute('aria-expanded', 'false'); };
  menu.hidden = false;
  menu.addEventListener('click', () => menu.setAttribute('aria-expanded', String(menu.getAttribute('aria-expanded') !== 'true')));
  nav.addEventListener('click', event => { if (event.target.closest('a')) closeMenu(); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape' && menu.getAttribute('aria-expanded') === 'true') { closeMenu(); menu.focus(); } });
  document.addEventListener('click', event => { if (!event.target.closest('.nav')) closeMenu(); });
  root.classList.add('enhanced');
  const progress = document.querySelector('.reading-progress');
  let pending = false;
  const updateProgress = () => {
    const available = document.documentElement.scrollHeight - innerHeight;
    progress.value = available > 0 ? Math.max(0, Math.min(100, scrollY / available * 100)) : 100;
    pending = false;
  };
  const scheduleProgress = () => { if (!pending) { pending = true; requestAnimationFrame(updateProgress); } };
  addEventListener('scroll', scheduleProgress, { passive: true });
  addEventListener('resize', scheduleProgress);
  addEventListener('load', scheduleProgress);
  updateProgress();
  // Print every answer, then restore the reader's disclosure choices afterwards.
  let printClosed = [];
  addEventListener('beforeprint', () => {
    printClosed = [...document.querySelectorAll('details:not([open])')];
    printClosed.forEach(details => { details.open = true; });
  });
  addEventListener('afterprint', () => {
    printClosed.forEach(details => { details.open = false; });
    printClosed = [];
  });
  document.querySelectorAll('.copy-email').forEach(button => button.addEventListener('click', async () => {
    const status = button.nextElementSibling;
    try {
      await navigator.clipboard.writeText('support@hydrodrop.us');
      status.textContent = 'Email address copied.';
    } catch {
      status.textContent = 'Select and copy support@hydrodrop.us, or use the email link below.';
    }
  }));
})();
