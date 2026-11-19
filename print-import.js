// Reads the print interior PDF (the file sent to IngramSpark/KDP) in the browser and returns the
// words on each printed page, keyed by the page number printed on that page. Running heads and
// footers (lines that repeat on many pages) and lines that are only a page number are left out,
// and words split by a hyphen at the end of a line are joined back together.
window.PrintImport = (function () {
  const PDFJS = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.4.168/build/pdf.min.mjs';
  const WORKER = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.4.168/build/pdf.worker.min.mjs';
  const norm = s => s.toLowerCase().replace(/[^a-z0-9]/g, '');

  // Turn pdf.js text items into lines (top to bottom) using their positions.
  function toLines(items) {
    const rows = [];
    for (const it of items) {
      if (!it.str) continue;
      const x = it.transform[4], y = it.transform[5], h = Math.abs(it.transform[3]) || 10;
      let row = rows.find(r => Math.abs(r.y - y) < h * 0.5);
      if (!row) { row = { y, h, parts: [] }; rows.push(row); }
      row.parts.push({ x, w: it.width || 0, s: it.str, h });
    }
    rows.sort((a, b) => b.y - a.y);
    return rows.map(r => {
      r.parts.sort((a, b) => a.x - b.x);
      let t = '', end = null;
      for (const p of r.parts) {
        if (end !== null && p.x - end > p.h * 0.18 && !t.endsWith(' ') && !p.s.startsWith(' ')) t += ' ';
        t += p.s; end = p.x + p.w;
      }
      return t.replace(/\s+/g, ' ').trim();
    }).filter(Boolean);
  }

  async function fromPdf(file, onProgress, lib) {
    const pdfjs = lib || await import(PDFJS);
    if (!lib) pdfjs.GlobalWorkerOptions.workerSrc = WORKER;
    const doc = await pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()) }).promise;
    const raw = [];
    for (let i = 1; i <= doc.numPages; i++) {
      const page = await doc.getPage(i);
      raw.push(toLines((await page.getTextContent()).items));
      if (onProgress) onProgress(i, doc.numPages);
    }
    // lines that repeat on 5+ pages are running heads or footers
    const seen = new Map();
    raw.forEach(lines => new Set(lines.map(l => norm(l.replace(/\d+/g, '')))).forEach(k => k && seen.set(k, (seen.get(k) || 0) + 1)));
    const pages = [];
    raw.forEach((lines, idx) => {
      // the printed page number is a line that is only a number, at the top or bottom of the page
      const edge = [lines[0], lines[lines.length - 1], lines[1], lines[lines.length - 2]].filter(Boolean);
      const numLine = edge.find(l => /^\d{1,4}$/.test(l));
      if (!numLine) return; // unnumbered page (title page, blank, front matter)
      const body = lines.filter(l => l !== numLine && !/^\d{1,4}$/.test(l) && (seen.get(norm(l.replace(/\d+/g, ''))) || 0) < 5);
      const text = body.join('\n').replace(/([A-Za-z])[-‐‑]\n([a-z])/g, '$1$2').replace(/\n/g, ' ');
      const words = text.split(/\s+/).filter(w => /[A-Za-z0-9]/.test(w));
      if (words.length) pages.push({ page: Number(numLine), pdf_page: idx + 1, words });
    });
    // keep one entry per printed page number
    const byPage = new Map(); pages.forEach(p => { if (!byPage.has(p.page)) byPage.set(p.page, p); });
    return { pdfPages: doc.numPages, pages: [...byPage.values()].sort((a, b) => a.page - b.page) };
  }

  return { fromPdf, _toLines: toLines };
})();
