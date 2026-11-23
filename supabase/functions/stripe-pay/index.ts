// stripe-pay: starts a Stripe Checkout payment and confirms it when the buyer returns.
// The price always comes from the database (license_plans), never from the browser.
// Large church purchases ($20,000+) can also be paid by Stripe invoice (bank transfer, ACH or card,
// due in 15 days; the church also can mail a check or wire). Open invoices are checked every 15 minutes by a scheduled job (x-notify-token)
// and whenever a leader opens the Leader Console.
// Secrets (set in Supabase › Edge Functions › Secrets): STRIPE_SECRET_KEY.
import { createClient } from 'npm:@supabase/supabase-js@2';

const SITE = 'https://time4god.app';
const ALLOWED_ORIGINS = ['https://time4god.app', 'https://www.time4god.app', 'https://merchcorphub.github.io'];
const RETURN_PAGES = ['/', '/index.html', '/access.html', '/read.html', '/leader.html', '/admin.html', '/challenges.html', '/church-signup.html', '/144p/church-signup.html', '/144p/', '/144p/access.html', '/144p/read.html', '/144p/leader.html', '/144p/admin.html'];

const cors = (origin: string | null) => ({
  'Access-Control-Allow-Origin': origin && ALLOWED_ORIGINS.includes(origin) ? origin : SITE,
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-notify-token',
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

// Check open invoices with Stripe: paid ones turn on seats, voided ones close.
async function syncInvoices(admin: any, key: string, user: string | null) {
  const { data: ids, error } = await admin.rpc('stripe_open_invoices', { p_user: user });
  if (error) throw new Error(error.message);
  const out: Record<string, string> = {};
  for (const id of (ids || []) as string[]) {
    try {
      const inv = await stripe('invoices/' + id, key);
      if (inv.status === 'paid') {
        const { data, error: e } = await admin.rpc('stripe_activate_invoice', { p_invoice: id, p_intent: typeof inv.payment_intent === 'string' ? inv.payment_intent : null, p_amount_cents: inv.amount_paid });
        out[id] = e ? 'error: ' + e.message : String(data);
      } else if (inv.status === 'void' || inv.status === 'uncollectible') {
        await admin.rpc('stripe_void_invoice', { p_invoice: id }); out[id] = 'void';
      } else out[id] = inv.status;
    } catch (e) { out[id] = 'error: ' + (e as Error).message; }
  }
  return out;
}

async function createInvoice(admin: any, key: string, paymentId: string) {
  const { data: ctx, error } = await admin.rpc('stripe_invoice_context', { p_payment: paymentId });
  if (error) throw new Error(error.message);
  const newCustomer = async () => {
    const c = await stripe('customers', key, { name: ctx.church_name, ...(ctx.email ? { email: ctx.email } : {}), 'metadata[church_id]': ctx.church_id }, 'cust-' + paymentId);
    await admin.rpc('stripe_set_customer', { p_church: ctx.church_id, p_customer: c.id });
    return c.id as string;
  };
  let customer: string = ctx.customer_id || await newCustomer();
  const base: Record<string, string> = {
    collection_method: 'send_invoice', days_until_due: String(ctx.days), auto_advance: 'true',
    pending_invoice_items_behavior: 'exclude',
    description: 'Time4God Challenge · study book seats for one year. Prices include tax. All sales are final. Seats turn on when this invoice is paid.',
    'metadata[payment_id]': paymentId,
  };
  const banks: Record<string, string> = {
    'payment_settings[payment_method_types][0]': 'customer_balance',
    'payment_settings[payment_method_types][1]': 'us_bank_account',
    'payment_settings[payment_method_types][2]': 'card',
    'payment_settings[payment_method_options][customer_balance][funding_type]': 'bank_transfer',
    'payment_settings[payment_method_options][customer_balance][bank_transfer][type]': 'us_bank_transfer',
  };
  const make = (tag: string, withBanks: boolean) => stripe('invoices', key, { ...base, customer, ...(withBanks ? banks : {}) }, tag + '-' + paymentId);
  let inv;
  try { inv = await make('inv', true); }
  catch (e) {
    if (/No such customer/i.test((e as Error).message || '')) {
      customer = await newCustomer();
      try { inv = await make('inv-c', true); } catch (_) { inv = await make('inv-c2', false); }
    } else {
      // Bank transfers not turned on in Stripe: use the account's default invoice payment methods.
      inv = await make('inv2', false);
    }
  }
  await stripe('invoiceitems', key, { customer, invoice: inv.id, amount: String(ctx.amount_cents), currency: 'usd', description: ctx.description }, 'item-' + paymentId);
  // Finalize only: the church gets our own Time4God invoice (PDF) by email, with this Stripe pay link on it.
  const sent = await stripe(`invoices/${inv.id}/finalize`, key, { auto_advance: 'false' }, 'fin-' + paymentId);
  const due = sent.due_date ? new Date(sent.due_date * 1000).toISOString().slice(0, 10) : null;
  await admin.rpc('stripe_attach_invoice', { p_payment: paymentId, p_invoice: sent.id, p_number: sent.number || null, p_url: sent.hosted_invoice_url || null, p_due: due, p_test: sent.livemode === false });
  const { data: doc } = await admin.from('invoice_docs').select('number').eq('payment_id', paymentId).maybeSingle();
  return { invoice_url: sent.hosted_invoice_url, number: (doc && doc.number) || sent.number, due_date: due };
}

// Which Stripe mode the secret key is in, and whether the account can take payments (never the key itself)
async function stripeStatus(raw: string) {
  const key = raw.trim();
  const kind = (key.match(/^(sk|rk|pk)_(live|test)_/) || [])[0] || (key.slice(0, 3) + '…');
  const out: Record<string, unknown> = { key_kind: kind, key_has_spaces: key !== raw, mode: /_live_/.test(kind) ? 'live' : /_test_/.test(kind) ? 'test' : 'unknown' };
  try {
    const bal = await stripe('balance', key); out.livemode = bal.livemode;
    const acct = await stripe('account', key);
    Object.assign(out, { name: (acct.business_profile && acct.business_profile.name) || acct.settings?.dashboard?.display_name || null,
      charges_enabled: acct.charges_enabled, payouts_enabled: acct.payouts_enabled, details_submitted: acct.details_submitted,
      requirements_due: (acct.requirements && acct.requirements.currently_due) || [] });
  } catch (e) { out.error = (e as Error).message; }
  return out;
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors(origin) });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405, origin);

  const key = Deno.env.get('STRIPE_SECRET_KEY');
  if (!key) return json({ error: 'Payments aren’t turned on yet. Please try again soon.' }, 503, origin);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  // Scheduled check from the database
  const notify = req.headers.get('x-notify-token');
  if (notify) {
    const { data: ok } = await admin.rpc('notify_token_ok', { t: notify });
    if (!ok) return json({ error: 'Not allowed.' }, 401, origin);
    let nb: Record<string, string> = {}; try { nb = await req.clone().json(); } catch (_) { /* none */ }
    if (nb.action === 'stripe_mode') return json(await stripeStatus(key), 200, origin);
    try { return json({ checked: await syncInvoices(admin, key, null) }, 200, origin); }
    catch (e) { return json({ error: (e as Error).message }, 500, origin); }
  }

  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: who } = await admin.auth.getUser(token);
  if (!who || !who.user) return json({ error: 'Please sign in again.' }, 401, origin);

  let body: Record<string, string> = {};
  try { body = await req.json(); } catch (_) { /* empty body */ }

  try {
    if (body.action === 'checkout') {
      const { data: prep, error } = await admin.rpc('stripe_prepare', {
        p_user: who.user.id, p_type: body.type, p_church: body.church_id || null, p_plan: body.plan_id || null,
        p_seats: body.seats ? parseInt(String(body.seats), 10) || null : null,
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
        // No custom_text: Stripe Managed Payments (on for this account) doesn't allow it. Buyers agree to
        // "all sales are final" on our own checkout step before they get here.
        success_url: `${base}${page}?paid={CHECKOUT_SESSION_ID}`,
        cancel_url: `${base}${page}?canceled=1`,
        ...(prep.email ? { customer_email: prep.email } : {}),
      }, prep.payment_id);
      await admin.rpc('stripe_attach_session', { p_payment: prep.payment_id, p_session: session.id });
      return json({ url: session.url }, 200, origin);
    }

    if (body.action === 'invoice') {
      if (body.type !== 'church') return json({ error: 'Invoices are for church seat purchases.' }, 400, origin);
      const { data: prep, error } = await admin.rpc('stripe_prepare', {
        p_user: who.user.id, p_type: 'church', p_church: body.church_id || null, p_plan: null,
        p_seats: body.seats ? parseInt(String(body.seats), 10) || null : null,
      });
      if (error) return json({ error: error.message }, 400, origin);
      try { return json(await createInvoice(admin, key, prep.payment_id), 200, origin); }
      catch (e) {
        const { data: kept } = await admin.from('payments').select('stripe_invoice_id').eq('id', prep.payment_id).maybeSingle();
        if (!kept || !kept.stripe_invoice_id) await admin.rpc('stripe_drop_payment', { p_payment: prep.payment_id });
        return json({ error: (e as Error).message || 'The invoice could not be created.' }, 400, origin);
      }
    }

    if (body.action === 'stripe_mode') {
      const { data: roles } = await admin.from('role_assignments').select('role').eq('user_id', who.user.id).eq('role', 'platform_admin').is('revoked_at', null).limit(1);
      if (!roles || !roles.length) return json({ error: 'Only an admin can see this.' }, 403, origin);
      return json(await stripeStatus(key), 200, origin);
    }

    // Admin: a check or wire arrived. Close any Stripe invoice as paid outside Stripe, then turn the seats on.
    if (body.action === 'mark_paid' || body.action === 'void_invoice') {
      const { data: roles } = await admin.from('role_assignments').select('role').eq('user_id', who.user.id).eq('role', 'platform_admin').is('revoked_at', null).not('verified_at', 'is', null).limit(1);
      if (!roles || !roles.length) return json({ error: 'Only an admin can do this.' }, 403, origin);
      const { data: doc } = await admin.from('invoice_docs').select('id,status,payment_id').eq('id', body.doc_id || '').maybeSingle();
      if (!doc) return json({ error: 'Invoice not found.' }, 404, origin);
      const { data: pay } = await admin.from('payments').select('stripe_invoice_id').eq('id', doc.payment_id).maybeSingle();
      const sid = pay && pay.stripe_invoice_id;
      if (sid && doc.status === 'open') {
        try {
          const inv = await stripe('invoices/' + sid, key);
          if (inv.status === 'open') {
            if (body.action === 'mark_paid') await stripe(`invoices/${sid}/pay`, key, { paid_out_of_band: 'true' }, 'oob-' + doc.id);
            else await stripe(`invoices/${sid}/void`, key, {}, 'void-' + doc.id);
          } else if (inv.status === 'paid' && body.action === 'void_invoice') {
            return json({ error: 'This invoice was already paid online. Refresh to see it.' }, 400, origin);
          }
        } catch (e) { return json({ error: 'Stripe: ' + (e as Error).message }, 502, origin); }
      }
      const r = body.action === 'mark_paid'
        ? await admin.rpc('stripe_mark_doc_paid', { p_doc: doc.id, p_method: body.method || 'check', p_reference: body.reference || null, p_user: who.user.id })
        : await admin.rpc('stripe_void_doc', { p_doc: doc.id, p_user: who.user.id });
      if (r.error) return json({ error: r.error.message }, 400, origin);
      return json({ ok: true, result: r.data }, 200, origin);
    }

    if (body.action === 'sync_invoices') {
      return json({ checked: await syncInvoices(admin, key, who.user.id) }, 200, origin);
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
