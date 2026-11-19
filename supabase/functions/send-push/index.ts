// send-push: delivers queued phone/desktop notifications (push_outbox) with Web Push.
// Woken by the database each minute when something is waiting. VAPID keys live in Supabase Vault.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from './webpush.ts';

Deno.serve(async (req) => {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const token = req.headers.get('x-notify-token') || '';
  const { data: ok } = await db.rpc('notify_token_ok', { t: token });
  if (!token || ok !== true) return new Response('Not allowed', { status: 403 });

  const { data: keys } = await db.rpc('push_keys');
  if (!keys || !keys.public || !keys.private) return new Response('Push keys missing', { status: 503 });
  const vapid = { publicKey: keys.public, privateKey: keys.private, subject: 'mailto:notifications@time4god.app' };

  const { data: rows, error } = await db.from('push_outbox')
    .select('id, attempts, payload, subscription_id, push_subscriptions(id, endpoint, p256dh, auth, failures)')
    .is('sent_at', null).lt('attempts', 3).order('id').limit(200);
  if (error) return new Response(error.message, { status: 500 });

  let sent = 0, gone = 0, failed = 0;
  for (const r of rows || []) {
    const s = r.push_subscriptions as unknown as { id: string; endpoint: string; p256dh: string; auth: string; failures: number } | null;
    if (!s) { await db.from('push_outbox').delete().eq('id', r.id); continue; }
    try {
      const res = await sendPush({ endpoint: s.endpoint, p256dh: s.p256dh, auth: s.auth }, r.payload, vapid);
      if (res.status >= 200 && res.status < 300) {
        await db.from('push_outbox').update({ sent_at: new Date().toISOString(), attempts: r.attempts + 1 }).eq('id', r.id);
        await db.from('push_subscriptions').update({ last_success_at: new Date().toISOString(), failures: 0 }).eq('id', s.id);
        sent++;
      } else if (res.status === 404 || res.status === 410) {
        await db.from('push_subscriptions').delete().eq('id', s.id); // the device unsubscribed; its queued pushes go with it
        gone++;
      } else {
        await db.from('push_outbox').update({ attempts: r.attempts + 1, last_error: `${res.status} ${res.text}` }).eq('id', r.id);
        await db.from('push_subscriptions').update({ failures: s.failures + 1 }).eq('id', s.id);
        failed++;
      }
    } catch (e) {
      await db.from('push_outbox').update({ attempts: r.attempts + 1, last_error: String(e).slice(0, 300) }).eq('id', r.id);
      failed++;
    }
  }
  return new Response(JSON.stringify({ sent, gone, failed }), { headers: { 'Content-Type': 'application/json' } });
});
