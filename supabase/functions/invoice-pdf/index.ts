// invoice-pdf: draws Time4God invoices and receipts as PDFs, saves them in the private
// "invoices" storage bucket ({church_id}/{number}.pdf), then asks the database to email
// the church a copy (send-emails attaches the PDF).
// Woken once a minute by the database (pg_cron + pg_net) only when an invoice needs drawing or sending.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { PDFDocument, StandardFonts, rgb, PDFFont, PDFPage } from 'npm:pdf-lib@1.17.1';

const NAVY = rgb(0x12 / 255, 0x3c / 255, 0x56 / 255);
const GOLD = rgb(0xc9 / 255, 0x9a / 255, 0x2e / 255);
const INK = rgb(0.13, 0.15, 0.18);
const MUTED = rgb(0.42, 0.45, 0.5);
const LINE = rgb(0.86, 0.88, 0.9);
const GREEN = rgb(0.1, 0.5, 0.28);
const RED = rgb(0.7, 0.16, 0.16);

const money = (n: number) => '$' + Number(n || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const day = (s?: string | null) => (s ? new Date(s.length <= 10 ? s + 'T12:00:00Z' : s).toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'America/New_York' }) : '');
// Standard fonts only carry WinAnsi characters; swap the common ones and drop the rest.
const clean = (s: unknown) => String(s ?? '').replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/[–—]/g, '-').replace(/·/g, '-').replace(/…/g, '...').replace(/[^\x0A\x20-\x7E\xA0-\xFF]/g, '');

function wrap(text: string, font: PDFFont, size: number, width: number): string[] {
  const out: string[] = [];
  for (const para of clean(text).split('\n')) {
    let line = '';
    for (const w of para.split(/\s+/)) {
      const t = line ? line + ' ' + w : w;
      if (font.widthOfTextAtSize(t, size) > width && line) { out.push(line); line = w; } else line = t;
    }
    out.push(line);
  }
  return out;
}

let logoBytes: Uint8Array | null = null;
async function logo() {
  if (logoBytes) return logoBytes;
  try { const r = await fetch('https://time4god.app/icon-192.png'); if (r.ok) logoBytes = new Uint8Array(await r.arrayBuffer()); } catch { /* draw without it */ }
  return logoBytes;
}

type Job = { doc: Record<string, any>; payable_to?: string; address?: string; wire?: string; terms?: string; support?: string; admins?: string[] };

async function draw(job: Job): Promise<Uint8Array> {
  const d = job.doc;
  const pdf = await PDFDocument.create();
  pdf.setTitle(`Time4God ${d.status === 'paid' ? 'Paid Invoice' : 'Invoice'} ${d.number}`);
  pdf.setAuthor(clean(job.payable_to || 'Time4God Challenge'));
  const page: PDFPage = pdf.addPage([612, 792]);
  const reg = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const serif = await pdf.embedFont(StandardFonts.TimesRomanBold);
  const W = 612, M = 48;
  const text = (s: unknown, x: number, y: number, o: { size?: number; font?: PDFFont; color?: any; right?: boolean } = {}) => {
    const f = o.font || reg, z = o.size || 10, t = clean(s);
    page.drawText(t, { x: o.right ? x - f.widthOfTextAtSize(t, z) : x, y, size: z, font: f, color: o.color || INK });
  };

  // Header band
  page.drawRectangle({ x: 0, y: 792 - 110, width: W, height: 110, color: NAVY });
  page.drawRectangle({ x: 0, y: 792 - 114, width: W, height: 4, color: GOLD });
  const lb = await logo();
  let tx = M;
  if (lb) { try { const img = await pdf.embedPng(lb); page.drawImage(img, { x: M, y: 792 - 95, width: 76, height: 76 }); tx = M + 90; } catch { /* no logo */ } }
  text('Time4God Challenge', tx, 792 - 48, { size: 20, font: serif, color: rgb(1, 1, 1) });
  text('The 144(P) Plan  -  time4god.app', tx, 792 - 66, { size: 10, color: rgb(0.85, 0.89, 0.93) });
  text(job.payable_to || '', tx, 792 - 82, { size: 9, color: rgb(0.85, 0.89, 0.93) });
  const title = d.status === 'paid' ? 'PAID INVOICE' : 'INVOICE';
  text(title, W - M, 792 - 50, { size: 22, font: bold, color: rgb(1, 1, 1), right: true });
  text(d.number, W - M, 792 - 70, { size: 11, color: GOLD, right: true });

  // Status stamp
  const stamp = d.status === 'paid' ? { t: 'PAID', c: GREEN } : d.status === 'void' ? { t: 'CANCELED', c: RED } : { t: 'PAYMENT DUE', c: GOLD };
  let y = 792 - 150;
  const sw = bold.widthOfTextAtSize(stamp.t, 11) + 20;
  page.drawRectangle({ x: W - M - sw, y: y - 6, width: sw, height: 22, borderColor: stamp.c, borderWidth: 1.5, color: rgb(1, 1, 1) });
  text(stamp.t, W - M - sw + 10, y + 1, { size: 11, font: bold, color: stamp.c });

  // Bill to / details
  text('BILL TO', M, y + 4, { size: 8, font: bold, color: MUTED });
  let by = y - 12;
  for (const [i, l] of [d.bill_to_name, d.bill_to_contact ? 'Attn: ' + d.bill_to_contact : '', ...(d.bill_to_address ? String(d.bill_to_address).split('\n') : []), d.bill_to_email].filter(Boolean).entries()) {
    text(l, M, by, { size: i === 0 ? 12 : 10, font: i === 0 ? bold : reg }); by -= i === 0 ? 16 : 13;
  }
  const facts: [string, string][] = [['Invoice number', d.number], ['Date issued', day(d.issued_at)]];
  if (d.status === 'paid') { facts.push(['Date paid', day(d.paid_at)]); facts.push(['Paid by', ({ card: 'Card (online)', online: 'Online payment', check: 'Check', wire: 'Wire transfer' } as any)[d.paid_method] || clean(d.paid_method || '')]); if (d.paid_reference) facts.push(['Reference', d.paid_reference]); }
  else if (d.status === 'open') facts.push(['Due date', day(d.due_date)]);
  let fy = y - 30;
  for (const [k, v] of facts) { text(k, W - M - 150, fy, { size: 9, color: MUTED }); text(v, W - M, fy, { size: 10, font: bold, right: true }); fy -= 15; }

  // Line items
  y = Math.min(by, fy) - 24;
  page.drawRectangle({ x: M, y: y - 6, width: W - 2 * M, height: 22, color: rgb(0.95, 0.96, 0.97) });
  const cQty = W - M - 200, cRate = W - M - 100;
  text('DESCRIPTION', M + 8, y + 1, { size: 8, font: bold, color: MUTED });
  text('SEATS', cQty, y + 1, { size: 8, font: bold, color: MUTED, right: true });
  text('PRICE / SEAT', cRate, y + 1, { size: 8, font: bold, color: MUTED, right: true });
  text('AMOUNT', W - M - 8, y + 1, { size: 8, font: bold, color: MUTED, right: true });
  y -= 24;
  const lines = wrap(d.description || 'Time4God Challenge seats', reg, 10, cQty - M - 70);
  text(lines[0], M + 8, y, { size: 10, font: bold });
  if (d.seats) text(Number(d.seats).toLocaleString('en-US'), cQty, y, { size: 10, right: true });
  if (d.unit_price) text(money(d.unit_price), cRate, y, { size: 10, right: true });
  text(money(d.amount), W - M - 8, y, { size: 10, right: true });
  for (const l of lines.slice(1)) { y -= 13; text(l, M + 8, y, { size: 9, color: MUTED }); }
  y -= 13; text('One-year license for the Time4God Challenge app and the full book, What Will You Give Today?', M + 8, y, { size: 9, color: MUTED });
  y -= 14; page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 1, color: LINE });

  // Totals
  y -= 20;
  const tot = (k: string, v: string, b = false, c = INK) => { text(k, cRate, y, { size: b ? 11 : 10, font: b ? bold : reg, right: true, color: b ? INK : MUTED }); text(v, W - M - 8, y, { size: b ? 13 : 10, font: b ? bold : reg, right: true, color: c }); y -= 18; };
  tot('Subtotal', money(d.amount));
  if (d.status === 'paid') { tot('Paid', '-' + money(d.amount), false, GREEN); tot('Balance due', '$0.00', true, GREEN); }
  else if (d.status === 'void') tot('Canceled', money(0), true, RED);
  else tot('Amount due', money(d.amount), true, NAVY);

  // How to pay
  if (d.status === 'open') {
    y -= 10;
    text('HOW TO PAY', M, y, { size: 9, font: bold, color: NAVY }); y -= 6;
    page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.75, color: GOLD }); y -= 16;
    const col = (W - 2 * M - 24) / 3;
    const blocks: [string, string][] = [];
    if (d.stripe_url) blocks.push(['Pay online', 'Card, ACH bank transfer or wire through our secure Stripe page. Use the "View and pay invoice" button in the email, or the link below.']);
    blocks.push(['Mail a check', `Make checks payable to ${job.payable_to || 'our ministry'} and write ${d.number} on the memo line.` + (job.address ? '\n\nMail to:\n' + job.address : '\n\nAsk us for our mailing address.')]);
    blocks.push(['Wire transfer', (job.wire ? job.wire : 'Ask us for wire instructions.') + `\n\nReference: ${d.number}`]);
    let low = y;
    blocks.forEach(([h, b], i) => {
      const x = M + i * (col + 12) + (blocks.length === 2 ? col / 2 : 0);
      let yy = y;
      text(h, x, yy, { size: 10, font: bold }); yy -= 14;
      for (const l of wrap(b, reg, 8.5, col - 4)) { text(l, x, yy, { size: 8.5, color: INK }); yy -= 11.5; }
      low = Math.min(low, yy);
    });
    y = low - 6;
    if (d.stripe_url) {
      text('Pay online:', M, y, { size: 8.5, font: bold }); y -= 11;
      for (const l of wrap(d.stripe_url, reg, 7.5, W - 2 * M).slice(0, 3)) { text(l, M, y, { size: 7.5, color: NAVY }); y -= 10; }
    }
    y -= 6;
    text('Your seats turn on as soon as your payment is received.', M, y, { size: 9, font: bold, color: GREEN });
  } else if (d.status === 'paid') {
    y -= 10;
    text('Thank you for your purchase. This invoice is paid in full and is your receipt.', M, y, { size: 10, font: bold, color: GREEN });
  }

  // Footer
  let fyy = 92;
  page.drawLine({ start: { x: M, y: fyy + 14 }, end: { x: W - M, y: fyy + 14 }, thickness: 0.75, color: LINE });
  for (const l of wrap(job.terms || '', reg, 8, W - 2 * M).slice(0, 3)) { text(l, M, fyy, { size: 8, color: MUTED }); fyy -= 11; }
  const contact = job.support || (job.admins && job.admins[0]) || '';
  text('Questions? ' + (contact ? 'Email ' + contact + ' or reply to the invoice email.' : 'Reply to the invoice email.'), M, fyy - 4, { size: 8, color: MUTED });
  const verse = '"Teach us to number our days, that we may gain a heart of wisdom." - Psalm 90:12';
  text(verse, (W - reg.widthOfTextAtSize(verse, 8)) / 2, 34, { size: 8, color: MUTED });
  if (d.test) text('TEST MODE - NOT A REAL CHARGE', W - M, 792 - 88, { size: 8, font: bold, color: rgb(1, 0.75, 0.75), right: true });
  return await pdf.save();
}

Deno.serve(async (req) => {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const token = req.headers.get('x-notify-token') || '';
  const { data: ok } = await db.rpc('notify_token_ok', { t: token });
  if (!token || ok !== true) return new Response('Not allowed', { status: 403 });

  const { data: jobs, error } = await db.rpc('invoice_jobs');
  if (error) return new Response(error.message, { status: 500 });
  const done: string[] = [], failed: string[] = [];
  for (const job of (jobs || []) as Job[]) {
    const d = job.doc;
    try {
      let path = d.pdf_path as string | null;
      if (d.pdf_dirty || !path) {
        const bytes = await draw(job);
        path = `${d.church_id || 'none'}/${d.number}.pdf`;
        const up = await db.storage.from('invoices').upload(path, bytes, { contentType: 'application/pdf', upsert: true });
        if (up.error) throw up.error;
      }
      const email = !!d.email_pending && !!d.bill_to_email;
      const r = await db.rpc('invoice_job_done', { p_doc: d.id, p_path: path, p_emailed: email });
      if (r.error) throw r.error;
      done.push(d.number);
    } catch (e) {
      console.error('invoice', d.number, e);
      failed.push(d.number + ': ' + String((e as any)?.message || e));
    }
  }
  return new Response(JSON.stringify({ done, failed }), { headers: { 'Content-Type': 'application/json' } });
});
