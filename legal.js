// legal.js: turns the Terms / Privacy text (simple Markdown) into HTML.
// Used by terms.html, privacy.html and the editor preview in Admin Panel › Settings.
(function () {
  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  function inline(s) {
    let t = esc(s);
    t = t.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, a, href) => /^(https?:|mailto:|[a-z0-9-]+\.html)/i.test(href) ? `<a href="${href}">${a}</a>` : a);
    t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>').replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    t = t.replace(/([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})(?![^<]*<\/a>)/g, '<a href="mailto:$1">$1</a>');
    return t;
  }
  function render(md) {
    const lines = String(md || '').replace(/\r/g, '').split('\n'), out = [], toc = [];
    let para = [], items = null; // items: [{text, sub: []}]
    const flushP = () => { if (para.length) { out.push('<p>' + para.map(inline).join('<br>') + '</p>'); para = []; } };
    const flushL = () => { if (items) { out.push('<ul>' + items.map(i => '<li>' + inline(i.text) + (i.sub.length ? '<ul>' + i.sub.map(x => '<li>' + inline(x) + '</li>').join('') + '</ul>' : '') + '</li>').join('') + '</ul>'); items = null; } };
    for (const raw of lines) {
      const line = raw.replace(/\s+$/, '');
      if (!line.trim()) { flushP(); flushL(); continue; }
      const h = line.match(/^(#{1,3})\s+(.*)$/), li = line.match(/^(\s*)[-*]\s+(.*)$/);
      if (h) { flushP(); flushL(); const lvl = h[1].length, id = h[2].toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
        if (lvl === 2) toc.push([id, h[2]]); out.push(`<h${lvl} id="${id}">${inline(h[2])}</h${lvl}>`); continue; }
      if (li) { flushP(); items = items || [];
        if (li[1].length >= 2 && items.length) items[items.length - 1].sub.push(li[2]); else items.push({ text: li[2], sub: [] });
        continue; }
      flushL(); para.push(line);
    }
    flushP(); flushL();
    return { html: out.join(''), toc };
  }
  function fill(md, v) {
    return String(md || '').replace(/\{\{support_email\}\}/g, v.support || 'support@time4god.app')
      .replace(/\{\{mailing_address\}\}/g, v.address || 'Georgia, United States')
      .replace(/\{\{effective_date\}\}/g, v.date || '');
  }
  window.Legal = { render, fill, esc };
})();
