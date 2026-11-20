// stripe-pay: starts a Stripe Checkout payment and confirms it when the buyer returns.
// The price always comes from the database (license_plans), never from the browser.
// Secrets (set in Supabase › Edge Functions › Secrets): STRIPE_SECRET_KEY.
import { createClient } from 'npm:@supabase/supabase-js@2';

const SITE = 'https://time4god.app';
const ALLOWED_ORIGINS = ['https://time4god.app', 'https://www.time4god.app', 'https://merchcorphub.github.io'];
const RETURN_PAGES = ['/', '/index.html', '/access.html', '/read.html', '/leader.html', '/admin.html', '/challenges.html', '/144p/', '/144p/access.html', '/144p/read.html', '/144p/leader.html', '/144p/admin.html'];

const cors = (origin: string | null) => ({
  'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : SITE,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
});

const json = (body: unknown, status: number, origin: string | null) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(origin), 'Content-Type': 'application/json' } });

async function stripe(path: string, key: string, params?: Record<string, string>, idem?: string) {
  const res = await fetch('https://api.stripe.com/v1/' + path, {
    method: params ? 'POST' : 'GET',
    headers: {
      Authorization: 'Bearer ' + key,
      ...(params ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}),
      ...(idem ? { 'Idempotency-Key': idem } : {}),
    },
    body: params ? new URLSearchParams(params) : undefined,
  });
  const data = await res.json();
  if (!res.ok) throw new Error((data && data.error && data.error.message) || 'Stripe did not accept the request.');
  return data;
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors(origin) });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405, origin);

  const key = Deno.env.get('STRIPE_SECRET_KEY');
  if (!key) return json({ error: 'Payments aren’t turned on yet. Please try again soon.' }, 503, origin);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: who } = await admin.auth.getUser(token);
  if (!who || !who.user) return json({ error: 'Please sign in again.' }, 401, origin);

  let body: Record<string, string> = {};
  try { body = await req.json(); } catch (_) { /* empty body */ }

  try {
    if (body.action === 'checkout') {
      const { data: prep, error } = await admin.rpc('stripe_prepare', {
        p_user: who.user.id, p_type: body.type, p_church: body.church_id || null, p_plan: body.plan_id || null,
      });
      if (error) return json({ error: error.message }, 400, origin);

      const base = origin && ALLOWED_ORIGINS.includes(origin) ? origin : SITE;
      const page = RETURN_PAGES.includes(body.return_path) ? body.return_path : '/read.html';
      const session = await stripe('checkout/sessions', key, {
        mode: 'payment',
        'line_items[0][quantity]': '1',
        'line_items[0][price_data][currency]': 'usd',
        'line_items[0][price_data][unit_amount]': String(prep.amount_cents),
        'line_items[0][price_data][product_data][name]': prep.description,
        client_reference_id: prep.payment_id,
        'metadata[payment_id]': prep.payment_id,
        'payment_intent_data[metadata][payment_id]': prep.payment_id,
        'custom_text[submit][message]': 'All sales are final. No refunds. Prices include tax.',
        success_url: `${base}${page}?paid={CHECKOUT_SESSION_ID}`,
        cancel_url: `${base}${page}?canceled=1`,
        ...(prep.email ? { customer_email: prep.email } : {}),
      }, prep.payment_id);
      await admin.rpc('stripe_attach_session', { p_payment: prep.payment_id, p_session: session.id });
      return json({ url: session.url }, 200, origin);
    }

    if (body.action === 'confirm') {
      const id = String(body.session_id || '');
      if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(id)) return json({ error: 'That payment link isn’t valid.' }, 400, origin);
      const s = await stripe('checkout/sessions/' + id, key);
      if (s.payment_status !== 'paid') {
        if (s.status === 'expired') { await admin.rpc('stripe_expire', { p_session: id }); return json({ status: 'expired' }, 200, origin); }
        return json({ status: 'unpaid' }, 200, origin);
      }
      const { data, error } = await admin.rpc('stripe_activate', { p_session: id, p_intent: s.payment_intent || null, p_amount_cents: s.amount_total });
      if (error) return json({ error: error.message }, 400, origin);
      return json({ status: 'paid', result: data }, 200, origin);
    }

    return json({ error: 'Unknown action.' }, 400, origin);
  } catch (e) {
    return json({ error: (e as Error).message || 'Payment could not be started.' }, 502, origin);
  }
});
