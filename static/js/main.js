/* ──────────────────────────────────────────────────────────
   WanderLog – main.js
   ────────────────────────────────────────────────────────── */

/* ── Star picker ────────────────────────────────────────── */
function initStarPicker(defaultRating = 5) {
  const picker = document.getElementById('starPicker');
  const hidden = document.getElementById('ratingHidden');
  if (!picker || !hidden) return;

  const stars = Array.from(picker.querySelectorAll('i'));
  let current = defaultRating;

  function render(n, isHover = false) {
    stars.forEach((s, i) => {
      s.classList.toggle('fas', i < n);
      s.classList.toggle('far', i >= n);
      s.classList.toggle('lit', i < n);
    });
  }

  // Set initial state
  render(current);

  stars.forEach((star, idx) => {
    const val = idx + 1;

    star.addEventListener('mouseover', () => render(val, true));
    star.addEventListener('mouseout',  () => render(current));
    star.addEventListener('click', () => {
      current = val;
      hidden.value = val;
      render(current);
    });
  });
}

/* ── Lightbox ───────────────────────────────────────────── */
function openLightbox(src) {
  const lb  = document.getElementById('lightbox');
  const img = document.getElementById('lightboxImg');
  if (!lb || !img) return;
  img.src = src;
  lb.classList.add('open');
  document.body.style.overflow = 'hidden';
}

function closeLightbox() {
  const lb = document.getElementById('lightbox');
  if (!lb) return;
  lb.classList.remove('open');
  document.body.style.overflow = '';
}

/* Close lightbox on Escape key */
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeLightbox();
});

/* ── Auto-dismiss flash alerts after 5 s ────────────────── */
document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('.alert').forEach(el => {
    setTimeout(() => {
      const bsAlert = bootstrap.Alert.getOrCreateInstance(el);
      bsAlert.close();
    }, 5000);
  });
});
