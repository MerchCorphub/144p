// 144(P) Plan — Supabase connection shared by the Partner and Admin apps.
// Local storage stays as the offline cache; writes queue in an outbox and flush when online.
(function () {
  const URL_ = 'https://nkmdddossplaaswsqnxb.supabase.co';
  const KEY_ = 'sb_publishable__wXTrGOqE-ynRJrdIQKT3Q_qW14o2eR';
  const OUTBOX = '144p-outbox-v1';
  let client = null, loading = null;

  function lib() {
    if (window.supabase && window.supabase.createClient) return Promise.resolve(window.supabase);
    if (!loading) loading = new Promise((res, rej) => { const s = document.createElement('script'); s.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2'; s.onload = () => res(window.supabase); s.onerror = rej; document.head.appendChild(s); });
    return loading;
  }
  async function sb() { if (!client) { const L = await lib(); client = L.createClient(URL_, KEY_, { auth: { persistSession: true, storageKey: '144p-auth' } }); } return client; }
  const ok = r => { if (r.error) throw r.error; return r.data; };
  const isUuid = s => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(s || ''));
  const ms = t => (t ? Date.parse(t) : null);
  const iso = n => (n ? new Date(n).toISOString() : null);

  // ---------- auth ----------
  async function session() { const c = await sb(); return (await c.auth.getSession()).data.session; }
  async function signUp(email, password, meta) {
    const c = await sb(); const d = ok(await c.auth.signUp({ email, password, options: { data: meta || {}, emailRedirectTo: location.href.split('?')[0] } }));
    return { user: d.user, session: d.session };
  }
  async function signIn(email, password) { const c = await sb(); return ok(await c.auth.signInWithPassword({ email, password })).session; }
  async function signOut() { try { const c = await sb(); await c.auth.signOut(); } catch (e) {} try { localStorage.removeItem(OUTBOX); } catch (e) {} }
  async function rpc(name, args) { const c = await sb(); return ok(await c.rpc(name, args || {})); }

  // ---------- partner ----------
  async function ensurePartner() {
    const c = await sb(), s = await session(); if (!s) return null;
    let p = ok(await c.from('partners').select('*').maybeSingle());
    if (!p) { const m = s.user.user_metadata || {}; p = ok(await c.from('partners').insert({ auth_user_id: s.user.id, first_name: m.first || 'Partner', last_name: m.last || '', email: s.user.email, timezone: m.tz || 'America/New_York' }).select().single()); }
    return p;
  }
  async function pullPartner() {
    const c = await sb(), p = await ensurePartner(); if (!p) return null;
    const [deps, notes, refl, reds, prefs, share, mem, tmr] = await Promise.all([
      c.from('time_deposits').select('*').then(ok), c.from('deposit_notes').select('*').then(ok), c.from('weekly_reflections').select('*').then(ok),
      c.from('time_redemptions').select('*').then(ok), c.from('notification_preferences').select('*').maybeSingle().then(ok),
      c.from('sharing_permissions').select('*').eq('owner_partner_id', p.id).then(ok),
      c.from('memberships').select('status, church_id, table_id, churches(name, slug), tables(name)').neq('status', 'removed').maybeSingle().then(ok),
      c.from('active_timers').select('*').maybeSingle().then(ok)]);
    const nm = Object.fromEntries(notes.map(n => [n.deposit_id, n.note || '']));
    return {
      partner: { id: p.id, first: p.first_name, last: p.last_name, email: p.email, pw: null, cloud: true, demo: false, start: p.account_start_date, created: ms(p.created_at), plan: p.giving_plan || '',
        churchId: mem ? mem.church_id : null, church: mem && mem.churches ? mem.churches.name : '', table: mem && mem.tables ? mem.tables.name : '', membership: mem ? mem.status : null },
      deposits: deps.map(d => ({ id: d.id, partnerId: p.id, category: d.category, minutes: d.minutes, date: d.activity_date, time: d.activity_time ? d.activity_time.slice(0, 5) : '', note: nm[d.id] || '', source: d.entry_method, createdAt: ms(d.created_at), updatedAt: ms(d.updated_at), voidedAt: ms(d.voided_at), clientKey: d.client_key })),
      reflections: Object.fromEntries(refl.map(r => [`${p.id}|${r.week_start_date}`, { meaningful: r.meaningful_time || '', next: r.next_week_plan || '', updatedAt: ms(r.updated_at) }])),
      redemptions: reds.map(r => ({ id: r.id, partnerId: p.id, itemId: null, title: r.title, detail: r.detail || '', slotId: null, cost: r.minute_cost, status: r.status === 'canceled' ? 'Cancelled' : 'Confirmed', createdAt: ms(r.created_at), clientKey: r.client_key })),
      prefs: prefs ? { reminder: prefs.reminder_enabled, time: (prefs.reminder_time || '07:00').slice(0, 5), tz: prefs.timezone || p.timezone } : null,
      timer: tmr ? { category: tmr.category, startedAt: ms(tmr.started_at) || Date.now(), accum: Number(tmr.accumulated_ms) || 0, running: tmr.running } : null,
      sharing: share.map(x => ({ id: x.id, owner: p.id, recipient: x.recipient_label || '', type: x.permission_type, enabled: x.enabled, createdAt: ms(x.created_at), revokedAt: ms(x.revoked_at) }))
    };
  }

  // ---------- outbox ----------
  const readBox = () => { try { return JSON.parse(localStorage.getItem(OUTBOX)) || []; } catch (e) { return []; } };
  const writeBox = b => { try { localStorage.setItem(OUTBOX, JSON.stringify(b)); } catch (e) {} };
  function queue(type, data) { const b = readBox(); b.push({ type, data, at: Date.now() }); writeBox(b); return flush(); }
  const OPS = {
    async deposit(c, d, pid) {
      ok(await c.from('time_deposits').upsert({ id: d.id, partner_id: pid, category: d.category, minutes: d.minutes, activity_date: d.date, activity_time: d.time || null, entry_method: d.source === 'timer' ? 'timer' : 'manual', client_key: d.clientKey || null, updated_at: iso(d.updatedAt), voided_at: iso(d.voidedAt) }));
      if (d.note) ok(await c.from('deposit_notes').upsert({ deposit_id: d.id, partner_id: pid, note: d.note.slice(0, 300) }));
      else ok(await c.from('deposit_notes').delete().eq('deposit_id', d.id));
    },
    async reflection(c, r, pid) { ok(await c.from('weekly_reflections').upsert({ partner_id: pid, week_start_date: r.week, meaningful_time: r.m || null, next_week_plan: r.n || null, updated_at: new Date().toISOString() }, { onConflict: 'partner_id,week_start_date' })); },
    async plan(c, r, pid) { ok(await c.from('partners').update({ giving_plan: r.plan || null }).eq('id', pid)); },
    async prefs(c, r, pid) { ok(await c.from('notification_preferences').upsert({ partner_id: pid, reminder_enabled: !!r.reminder, reminder_time: r.time || '07:00', timezone: r.tz || null })); },
    async sharing(c, r, pid) { ok(await c.from('sharing_permissions').upsert({ id: r.id, owner_partner_id: pid, recipient_label: r.recipient, permission_type: r.type || 'weekly_balance', enabled: r.enabled, revoked_at: iso(r.revokedAt) })); },
    async redeem(c, r) { ok(await c.rpc('redeem_time', { p_title: r.title, p_detail: r.detail || null, p_cost: r.cost, p_client_key: r.clientKey })); },
    async timer(c, t, pid) {
      if (!t) ok(await c.from('active_timers').delete().eq('partner_id', pid));
      else ok(await c.from('active_timers').upsert({ partner_id: pid, category: t.category, started_at: iso(t.startedAt), accumulated_ms: Math.round(t.accum || 0), running: !!t.running }));
    },
    async touch(c) { ok(await c.rpc('touch_activity')); }
  };
  let flushing = null, pidCache = null;
  function flush() {
    if (flushing) return flushing;
    flushing = (async () => {
      const failed = [];
      try {
        if (!navigator.onLine) return { pending: readBox().length };
        const c = await sb(), s = await session(); if (!s) return { pending: readBox().length };
        if (!pidCache) { const p = ok(await c.from('partners').select('id').maybeSingle()); pidCache = p && p.id; }
        let box = readBox();
        while (box.length) {
          const op = box[0];
          try { await OPS[op.type](c, op.data, pidCache); }
          catch (e) { if (e && (e.status >= 500 || /fetch|network/i.test(e.message || ''))) break; failed.push({ op, error: e.message || String(e) }); }
          box = readBox(); box.shift(); writeBox(box);
        }
        return { pending: readBox().length, failed };
      } catch (e) { return { pending: readBox().length, failed, error: e.message }; }
      finally { flushing = null; }
    })();
    return flushing;
  }
  window.addEventListener('online', () => flush());

  window.Cloud = { url: URL_, sb, session, signUp, signIn, signOut, rpc, ensurePartner, pullPartner, queue, flush, pending: () => readBox().length, isUuid, ms, iso, ok, resetPid: () => { pidCache = null; } };
})();
