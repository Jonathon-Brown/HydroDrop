(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  // Match MascotMood.forProgress in MascotView.swift. Images are native SwiftUI renders.
  const moods = ['Parched', 'Thirsty', 'Doing okay', 'Feeling great', 'Fully hydrated!'];
  let total = 1000;
  const render = () => {
    const fraction = total / 2000;
    const index = fraction < .15 ? 0 : fraction < .4 ? 1 : fraction < .75 ? 2 : fraction < 1 ? 3 : 4;
    $('demo-mascot').src = `assets/mascots/classic-${index}.webp`;
    $('demo-mascot').alt = `Classic droplet: ${moods[index]}`;
    $('demo-total').textContent = `${total.toLocaleString('en-US')} mL`;
    $('demo-mood').textContent = `${moods[index]} · ${Math.round(fraction * 100)}% of 2,000 mL`;
    $('demo-progress').value = total;
  };
  document.querySelectorAll('[data-add]').forEach(button => button.addEventListener('click', () => {
    total = Math.min(2000, total + Number(button.dataset.add)); render();
  }));
  $('reset').addEventListener('click', () => { total = 0; render(); });
  $('parse').addEventListener('click', () => {
    const expanded = $('parse').getAttribute('aria-expanded') !== 'true';
    $('parse').setAttribute('aria-expanded', String(expanded));
    $('drink-results').hidden = !expanded;
  });
  $('tap').addEventListener('click', () => {
    $('tap-status').textContent = 'Example: 500 mL bottle logged. One tap, done.';
    $('tap').classList.remove('pulse');
    void $('tap').offsetWidth;
    $('tap').classList.add('pulse');
  });
  const skins = {
    classic: ['Classic', 'The original drop'], sunrise: ['Sunrise', 'Warm morning halo'],
    forest: ['Forest', 'Grows a leafy sprout'], grape: ['Grape', 'Fizzing with bubbles'],
    midnight: ['Midnight', 'Lit by tiny stars']
  };
  let selection = 0;
  const status = document.getElementById('skin-status');
  document.querySelectorAll('button[data-skin]').forEach(button => button.addEventListener('click', async () => {
    const skin = button.dataset.skin;
    if (!Object.hasOwn(skins, skin)) return;
    const current = ++selection;
    const [name, tagline] = skins[skin];
    const mascot = new Image();
    const icon = new Image();
    status.textContent = `Loading ${name}…`;
    mascot.src = `/assets/mascots/${skin}-4.webp`;
    icon.src = `/assets/icons/${skin}.webp`;
    try {
      await Promise.all([mascot.decode(), icon.decode()]);
      // Rapidly choosing another skin must not let a slower previous image win.
      if (current !== selection) return;
      $('skin-mascot').src = mascot.src;
      $('skin-mascot').alt = `${name} mascot: ${tagline}`;
      $('skin-icon').src = icon.src;
      $('skin-icon').alt = `${name} app icon`;
      $('skin-name').textContent = name;
      $('skin-tagline').textContent = tagline;
      $('skin-tier').textContent = skin === 'classic' ? 'Included free' : 'With HydroDrop+';
      document.querySelectorAll('button[data-skin]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
      status.textContent = '';
    } catch {
      if (current === selection) status.textContent = 'That look could not load. Please try again.';
    }
  }));
  if ('IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const observer = new IntersectionObserver(entries => entries.forEach(entry => {
      if (entry.isIntersecting) { entry.target.classList.add('visible'); observer.unobserve(entry.target); }
    }), { threshold: .08 });
    document.documentElement.classList.add('motion');
    document.querySelectorAll('.reveal').forEach(element => observer.observe(element));
  }
})();
