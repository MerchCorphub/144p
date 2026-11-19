// send-emails: sends what the database queued in email_outbox, through Resend.
// Woken once a minute by the database (pg_cron + pg_net) only when emails are waiting.
// Secret: RESEND_API_KEY (from resend.com). The cron job proves itself with a token kept in Supabase Vault.
// Optional: EMAIL_FROM (default "Time4God Challenge <notifications@time4god.app>"), EMAIL_REPLY_TO.
import { createClient } from 'npm:@supabase/supabase-js@2';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const token = req.headers.get('x-notify-token') || '';
  const { data: ok } = await db.rpc('notify_token_ok', { t: token });
  if (!token || ok !== true) return new Response('Not allowed', { status: 403 });

  const key = Deno.env.get('RESEND_API_KEY');
  if (!key) return new Response(JSON.stringify({ waiting: true, reason: 'RESEND_API_KEY is not set yet' }), { status: 503 });

  const from = Deno.env.get('EMAIL_FROM') || 'Time4God Challenge <notifications@time4god.app>';
  const replyTo = Deno.env.get('EMAIL_REPLY_TO');

  const { data: rows, error } = await db.from('email_outbox')
    .select('id,to_email,subject,html,body_text,attempts')
    .is('sent_at', null).lt('attempts', 5).order('id').limit(40);
  if (error) return new Response(error.message, { status: 500 });

  let sent = 0, failed = 0;
  for (const m of rows || []) {
    try {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json', 'Idempotency-Key': 'outbox-' + m.id },
        body: JSON.stringify({ from, to: [m.to_email], subject: m.subject, html: m.html, text: m.body_text, ...(replyTo ? { reply_to: replyTo } : {}) }),
      });
      if (res.ok) {
        await db.from('email_outbox').update({ sent_at: new Date().toISOString(), attempts: m.attempts + 1, last_error: null }).eq('id', m.id);
        sent++;
      } else {
        const t = await res.text();
        await db.from('email_outbox').update({ attempts: m.attempts + 1, last_error: t.slice(0, 500) }).eq('id', m.id);
        failed++;
      }
    } catch (e) {
      await db.from('email_outbox').update({ attempts: m.attempts + 1, last_error: String(e).slice(0, 500) }).eq('id', m.id);
      failed++;
    }
    await sleep(600); // stay under Resend's 2-per-second limit
  }
  return new Response(JSON.stringify({ sent, failed }), { headers: { 'Content-Type': 'application/json' } });
});
