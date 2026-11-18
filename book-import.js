// 144(P) Plan — turns the book's Word file (converted to HTML by mammoth) into app sections.
// Sections unlock by week: 0 = available from the start, 1–12 = that challenge week.
(function (root) {
  const LEVELS = [[1, 'Starter', 1, 3], [2, 'Builder', 4, 6], [3, 'Faithful', 7, 9], [4, 'Achiever', 10, 12]];
  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const norm = s => String(s || '').replace(/\s+/g, ' ').trim();

  function splitBook(html, parseHTML) {
    const doc = parseHTML(`<div id="root">${html}</div>`);
    const rootEl = doc.getElementById('root');
    const bl = Array.from(rootEl.children);
    const txt = i => norm(bl[i].textContent);
    const find = (re, start) => {
      for (let i = start || 0; i < bl.length; i++) if (re.test(txt(i))) return i;
      throw new Error('Could not find "' + re.source.replace(/\\/g, '').replace(/^\^|\$$/g, '') + '" in the book file.');
    };
    const clean = (a, b) => {
      const out = [];
      for (const el of bl.slice(a, b)) {
        const t = norm(el.textContent), tag = el.tagName.toLowerCase();
        el.querySelectorAll('img').forEach(im => im.remove());
        if (tag === 'table' && (!t || /^(Sun Mon Tue Wed Thu Fri Sat|Signed( Signed)?|Signed Witnessed by|Date I prayed for How God answered Date)$/.test(t))) continue;
        if (!t) { if (el.querySelector('hr') || tag === 'hr') out.push('<hr>'); continue; }
        if (tag === 'p' && t === t.toUpperCase() && t.length < 70 && /[A-Z]/.test(t)) { out.push(`<p class="label">${esc(t)}</p>`); continue; }
        const prevLabel = out.length && out[out.length - 1].startsWith('<p class="label">');
        if (tag === 'p' && prevLabel && t.length < 60 && !/[.?!,:;”"]$/.test(t) && !el.querySelector('em,strong')) { out.push(`<h3>${esc(t)}</h3>`); continue; }
        if (/^h[1-6]$/.test(tag)) { out.push(`<h2>${esc(t)}</h2>`); continue; }
        el.querySelectorAll('[style],[class],[id]').forEach(x => { x.removeAttribute('style'); x.removeAttribute('class'); x.removeAttribute('id'); });
        el.removeAttribute('style'); el.removeAttribute('class'); el.removeAttribute('id');
        el.querySelectorAll('a[id]').forEach(x => x.remove());
        out.push(el.outerHTML);
      }
      return out.join('\n');
    };
    const secs = [];
    const add = (slug, title, kind, week, a, b) => secs.push({ slug, title, kind, unlock_week: week, sort_order: secs.length + 1, content_html: clean(a, b) });

    const I = {
      dedication: find(/^DEDICATION$/), gift: find(/^A GIFT OF TIME$/), together: find(/^READ IT TOGETHER$/), contents: find(/^Contents$/i),
      letter: find(/^A LETTER FROM THE AUTHOR$/), start: find(/^START HERE$/), part1: find(/^PART ONE$/),
    };
    I.meetEnd = find(/^LEVEL 1 · WEEKS 1–3$/, I.part1);
    add('dedication', 'Dedication', 'intro', 0, I.dedication, I.gift);
    add('read-together', 'One for You, One for Someone You Love', 'intro', 0, I.together, I.contents);
    add('letter', 'A Letter from the Author', 'intro', 0, I.letter, I.start);
    add('how-to-use', 'How to Use This Gift', 'intro', 0, I.start, I.part1);
    add('meet-the-table', 'Meet the Table', 'intro', 0, I.part1, I.meetEnd);
    let pos = I.meetEnd;
    for (const [n, name, a, b] of LEVELS) {
      const lv = find(new RegExp(`^LEVEL ${n} · WEEKS ${a}–${b}$`), pos);
      const w1 = find(new RegExp(`^WEEK ${a} · LIFE AT THE TABLE$`), lv);
      add(`level-${n}`, `Level ${n} · ${name}`, 'level', a, lv, w1);
      for (let w = a; w <= b; w++) {
        const st = find(new RegExp(`^WEEK ${w} · LIFE AT THE TABLE$`), pos);
        const jr = find(new RegExp(`^WEEK ${w} · JOURNAL$`), st);
        const nx = find(new RegExp(`^(WEEK ${w + 1} · LIFE AT THE TABLE|LEVEL ${n} COMPLETE\\?)$`), jr);
        add(`week-${w}`, `Week ${w} · ${txt(st + 1)}`, 'week', w, st, jr);
        add(`week-${w}-journal`, `Week ${w} · Journal`, 'journal', w, jr, nx);
        pos = nx;
      }
      const cp = find(new RegExp(`^LEVEL ${n} COMPLETE\\?$`), pos);
      const end = find(new RegExp(`^(LEVEL ${n + 1} · WEEKS .*|PART TWO)$`), cp);
      add(`checkpoint-${n}`, `${name} Checkpoint`, 'checkpoint', b, cp, end);
      pos = end;
    }
    const p2 = find(/^PART TWO$/, pos), adv = find(/^FOR THE CHRISTMAS SEASON$/, p2), xmas = find(/^DECEMBER 25$/, adv);
    const prayer = find(/^PRAYER PAGES$/, xmas), close = find(/^TO CLOSE$/, prayer), cert = find(/^CERTIFICATE OF COMPLETION$/, close);
    const passIt = find(/^PASS IT ON$/, cert), about = find(/^ABOUT THE AUTHOR$/, passIt);
    add('better-together', 'Part Two · Better Together (for group leaders)', 'guide', 0, p2, adv);
    add('advent-bridge', 'For the Christmas Season: The Advent Bridge', 'extra', 0, adv, xmas);
    add('christmas-day', 'Christmas Day at the Table', 'extra', 0, xmas, prayer);
    add('closing-blessing', 'A Closing Blessing', 'closing', 12, close, cert);
    add('giving-this-book', 'Giving This Book to Others', 'closing', 12, passIt, about);
    add('about-the-author', 'About the Author', 'intro', 0, about, bl.length);
    return secs;
  }

  // Browser: Word file -> sections, using mammoth from the CDN
  async function fromDocx(file) {
    if (!root.mammoth) await new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'https://cdn.jsdelivr.net/npm/mammoth@1.8.0/mammoth.browser.min.js'; s.onload = res; s.onerror = () => rej(new Error('Could not load the Word reader. Check your connection.')); document.head.appendChild(s); });
    const buf = await file.arrayBuffer();
    const r = await root.mammoth.convertToHtml({ arrayBuffer: buf });
    return splitBook(r.value, h => new DOMParser().parseFromString(h, 'text/html'));
  }

  const api = { splitBook, fromDocx };
  if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.BookImport = api;
})(typeof window !== 'undefined' ? window : globalThis);
