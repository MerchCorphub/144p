/* time4god member reviews: summary widget (top 3) and the full reviews list.
   Needs cloud.js loaded first. Only approved reviews ever reach this script. */
(function () {
  const esc = s => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const CSS = `
.rv{font-family:'Public Sans',system-ui,sans-serif;color:#14284B}
.rv-card{background:#fff;border:1px solid #E6DFCC;border-radius:14px;box-shadow:0 1px 2px rgba(11,34,87,.05);padding:18px;margin-top:16px}
.rv-head{display:flex;align-items:center;gap:14px;flex-wrap:wrap}
.rv-avg{font-family:'Source Serif 4',Georgia,serif;font-size:40px;font-weight:600;color:#0B2257;line-height:1}
.rv-stars{color:#C98A0B;letter-spacing:2px;font-size:18px;white-space:nowrap}
.rv-stars .off{color:#D8D2C2}
.rv-count{font-size:14px;color:#4F5F68}
.rv-title{font-family:'Source Serif 4',Georgia,serif;font-size:22px;font-weight:600;color:#0B2257;margin:0 0 10px}
.rv-item{border-top:1px solid #EEE7D6;padding:14px 0 4px}
.rv-item:first-of-type{border-top:0}
.rv-meta{font-size:13px;color:#4F5F68;margin-top:2px}
.rv-tag{display:inline-block;border-radius:999px;padding:3px 10px;font-size:12px;font-weight:700;background:#E8F5F3;color:#075D61;margin-top:8px}
.rv-q{font-size:13px;font-weight:700;color:#4F5F68;margin:10px 0 2px}
.rv-a{font-size:15px;line-height:1.55;margin:0;white-space:pre-wrap;word-break:break-word}
.rv-help{display:inline-flex;align-items:center;gap:6px;min-height:40px;margin-top:10px;padding:0 14px;border:1px solid #C9D3D8;border-radius:999px;background:#fff;color:#173344;font:inherit;font-size:14px;cursor:pointer}
.rv-help[aria-pressed=true]{background:#E8F5F3;border-color:#075D61;color:#075D61;font-weight:700}
.rv-help[disabled]{cursor:default;opacity:.75}
.rv-btn{display:flex;align-items:center;justify-content:center;width:100%;min-height:48px;border-radius:12px;border:1px solid #0B2257;background:#fff;color:#0B2257;font:inherit;font-weight:600;font-size:16px;cursor:pointer;text-decoration:none;margin-top:12px}
.rv-btn.main{background:#0B2257;color:#fff}
.rv-bars{display:grid;grid-template-columns:auto 1fr auto;gap:6px 10px;align-items:center;font-size:14px;margin-top:14px}
.rv-bar{height:10px;border-radius:999px;background:#EEE7D6;overflow:hidden}
.rv-bar span{display:block;height:100%;background:#C98A0B;border-radius:999px}
.rv-filters{display:flex;gap:8px;flex-wrap:wrap;margin-top:14px}
.rv-f{min-height:40px;padding:0 14px;border-radius:999px;border:1px solid #C9D3D8;background:#fff;color:#173344;font:inherit;font-size:14px;cursor:pointer}
.rv-f[aria-pressed=true]{background:#0B2257;border-color:#0B2257;color:#fff;font-weight:700}
.rv-note{font-size:13px;color:#4F5F68;margin-top:12px;line-height:1.5}
.rv-err{background:#FBEAE7;color:#7A2A20;border-radius:10px;padding:10px 12px;margin-top:12px;font-size:14px}
.rv button:focus-visible,.rv a:focus-visible{outline:3px solid #0E8A7E;outline-offset:2px}`;
  function addCss() { if (document.getElementById('rv-css')) return; const s = document.createElement('style'); s.id = 'rv-css'; s.textContent = CSS; document.head.appendChild(s); }
  const stars = n => { const k = Math.round(Number(n) || 0); return `<span class="rv-stars" aria-hidden="true">${'★'.repeat(k)}<span class="off">${'★'.repeat(5 - k)}</span></span>`; };
  const starsLabel = n => `${n} out of 5 stars`;
  async function signedIn() { try { return !!(window.Cloud && await Cloud.session()); } catch (e) { return false; } }
  async function load(filter, offset, limit) { return await Cloud.rpc('public_reviews', { p_filter: filter || null, p_offset: offset || 0, p_limit: limit || 10 }); }

  function itemHtml(r, canVote) {
    const helpTxt = r.helpful ? `Helpful · ${r.helpful}` : 'Was this helpful?';
    const btn = r.mine ? `<span class="rv-meta">Your review${r.helpful ? ' · ' + r.helpful + ' found it helpful' : ''}</span>`
      : `<button class="rv-help" type="button" data-id="${esc(r.id)}" aria-pressed="${r.voted ? 'true' : 'false'}"${canVote ? '' : ' data-signin="1"'}>👍 ${esc(helpTxt)}</button>`;
    return `<div class="rv-item"><div role="img" aria-label="${starsLabel(r.stars)}">${stars(r.stars)}</div>
      <div class="rv-meta"><strong style="color:#173344">${esc(r.name)}</strong> · ${esc(r.month)}</div>
      ${r.discovery ? `<span class="rv-tag">God showed me: ${esc(r.discovery)}</span>` : ''}
      ${r.changed ? `<div class="rv-q">What changed</div><p class="rv-a">${esc(r.changed)}</p>` : ''}
      ${r.recommend ? `<div class="rv-q">I’d recommend it to</div><p class="rv-a">${esc(r.recommend)}</p>` : ''}
      ${btn}</div>`;
  }
  function wireVotes(root, onSignin) {
    root.querySelectorAll('.rv-help').forEach(b => b.addEventListener('click', async () => {
      if (b.dataset.signin) return onSignin();
      b.disabled = true;
      try { const r = await Cloud.rpc('review_vote', { p_review: b.dataset.id }); b.setAttribute('aria-pressed', r.voted ? 'true' : 'false'); b.textContent = '👍 ' + (r.helpful ? 'Helpful · ' + r.helpful : 'Was this helpful?'); }
      catch (e) { alert((e && e.message) || 'Could not save that. Please try again.'); }
      b.disabled = false;
    }));
  }
  const toSignin = () => { if (confirm('Sign in to the app to mark reviews helpful?')) location.href = './'; };

  // Summary: average, count and the top 3 most helpful reviews. Hidden until there is at least one approved review.
  async function summary(el, opts) {
    if (!el) return; addCss(); opts = opts || {};
    try {
      const [d, me] = await Promise.all([load(null, 0, opts.top || 3), signedIn()]);
      if (!d || !d.count) { el.hidden = true; return; }
      el.hidden = false; el.classList.add('rv');
      el.innerHTML = `<div class="rv-card"><h2 class="rv-title">${esc(opts.title || 'What members say')}</h2>
        <div class="rv-head"><span class="rv-avg">${esc(d.average)}</span><div><div role="img" aria-label="Average ${esc(d.average)} out of 5 stars">${stars(d.average)}</div><div class="rv-count">${esc(d.count)} member review${d.count == 1 ? '' : 's'}</div></div></div>
        ${(d.items || []).map(r => itemHtml(r, me)).join('')}
        <a class="rv-btn" href="reviews.html">See all reviews ›</a></div>`;
      wireVotes(el, toSignin);
    } catch (e) { el.hidden = true; }
  }

  // Full list: breakdown, filter buttons, 10 at a time.
  async function full(el) {
    addCss(); el.classList.add('rv');
    const st = { filter: null, items: [], matching: 0, base: null, me: await signedIn(), err: '' };
    async function fetchPage(reset) {
      try {
        const d = await load(st.filter, reset ? 0 : st.items.length, 10);
        if (!st.base || reset && !st.filter) st.base = d;
        st.items = reset ? d.items : st.items.concat(d.items); st.matching = d.matching; st.err = '';
      } catch (e) { st.err = 'Reviews couldn’t load. Please try again.'; }
      draw();
    }
    function draw() {
      const b = st.base;
      if (!b) { el.innerHTML = st.err ? `<div class="rv-err">${esc(st.err)}</div>` : ''; return; }
      if (!b.count) { el.innerHTML = `<div class="rv-card"><h2 class="rv-title">Member reviews</h2><p class="rv-a">No reviews yet. Members can share theirs after they finish the 12 weeks.</p><a class="rv-btn main" href="./#review">Write a review</a></div>`; return; }
      const max = Math.max(1, ...['5', '4', '3', '2', '1'].map(k => b.breakdown[k] || 0));
      el.innerHTML = `<div class="rv-card"><div class="rv-head"><span class="rv-avg">${esc(b.average)}</span><div><div role="img" aria-label="Average ${esc(b.average)} out of 5 stars">${stars(b.average)}</div><div class="rv-count">${esc(b.count)} member review${b.count == 1 ? '' : 's'}</div></div></div>
          <div class="rv-bars">${['5', '4', '3', '2', '1'].map(k => `<span>${k} ★</span><span class="rv-bar" role="img" aria-label="${b.breakdown[k] || 0} reviews with ${k} stars"><span style="width:${Math.round((b.breakdown[k] || 0) / max * 100)}%"></span></span><span>${b.breakdown[k] || 0}</span>`).join('')}</div>
          ${b.filters && b.filters.length ? `<div class="rv-q" style="margin-top:16px">What God showed them</div><div class="rv-filters"><button class="rv-f" type="button" data-f="" aria-pressed="${st.filter ? 'false' : 'true'}">All</button>${b.filters.map(f => `<button class="rv-f" type="button" data-f="${esc(f.label)}" aria-pressed="${st.filter === f.label ? 'true' : 'false'}">${esc(f.label)} (${esc(f.n)})</button>`).join('')}</div>` : ''}
          <a class="rv-btn main" href="./#review">Write a review</a></div>
        <div class="rv-card">${st.items.length ? st.items.map(r => itemHtml(r, st.me)).join('') : '<p class="rv-a">No reviews match that filter yet.</p>'}
          ${st.items.length < st.matching ? '<button class="rv-btn" type="button" id="rv-more">Show more</button>' : ''}</div>
        ${st.err ? `<div class="rv-err">${esc(st.err)}</div>` : ''}
        <p class="rv-note">Reviews come from members who finished the 12 weeks and are checked by the time4god team before they appear. They reflect each member’s own experience, not promised results. Most helpful reviews are shown first.</p>`;
      el.querySelectorAll('.rv-f').forEach(x => x.addEventListener('click', () => { st.filter = x.dataset.f || null; fetchPage(true); }));
      const more = el.querySelector('#rv-more'); if (more) more.addEventListener('click', () => { more.disabled = true; fetchPage(false); });
      wireVotes(el, toSignin);
    }
    await fetchPage(true);
  }

  window.T4GReviews = { summary, full };
})();
