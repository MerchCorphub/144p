// 144(P) Plan — multi-church admin data layer (local test-mode store; mirrors the Supabase schema in naming)
(function () {
  const AKEY = '144p-admin-v1';
  const pad = n => String(n).padStart(2, '0');
  const ymd = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const toUTC = s => { const [y, m, d] = s.split('-').map(Number); return Date.UTC(y, m - 1, d); };
  const fromUTC = t => { const d = new Date(t); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`; };
  const addDays = (s, n) => fromUTC(toUTC(s) + n * 864e5);
  const diffDays = (a, b) => Math.round((toUTC(b) - toUTC(a)) / 864e5);
  const addMonths = (s, n) => { const [y, m, d] = s.split('-').map(Number); const dt = new Date(Date.UTC(y, m - 1 + n, 1)); const last = new Date(Date.UTC(dt.getUTCFullYear(), dt.getUTCMonth() + 1, 0)).getUTCDate(); return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(Math.min(d, last))}`; };
  const slugify = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const uid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
  async function sha(s) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)); return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join(''); }

  const PLANS = [
    { id: 'small', name: 'Small Church', monthly: 29, annual: 290, limit: 25, status: 'published', features: ['statements', 'enrollment'] },
    { id: 'growing', name: 'Growing Church', monthly: 59, annual: 590, limit: 100, status: 'published', features: ['statements', 'enrollment', 'tables'] },
    { id: 'large', name: 'Large Church', monthly: 119, annual: 1190, limit: 500, status: 'published', features: ['statements', 'enrollment', 'tables', 'reports'] },
    { id: 'enterprise', name: 'Enterprise', monthly: null, annual: null, limit: null, status: 'published', custom: true, features: ['all'] }];

  const SEED = [
    ['Grace Fellowship', 'Springfield', 'MO', 'Sarah Miller', 'Senior Pastor', 'growing', 'monthly', 'active', 88, 10],
    ['Kingdom Life Center', 'Raleigh', 'NC', 'Marcus Allen', 'Executive Pastor', 'large', 'annual', 'active', 412, 9],
    ['Mt. Olive Church', 'Franklin', 'TN', 'Denise Carter', 'Discipleship Director', 'large', 'monthly', 'active', 305, 8],
    ['New Hope Baptist Church', 'Greenville', 'SC', 'James Parker', 'Pastor', 'growing', 'monthly', 'active', 94, 7],
    ['Riverside Church', 'Austin', 'TX', 'Elena Ruiz', 'Office Manager', 'small', 'monthly', 'past_due', 22, 6],
    ['Willow Creek Chapel', 'Boise', 'ID', 'Tom Becker', 'Pastor', 'small', 'monthly', 'canceled', 14, 9],
    ['Cornerstone Community', 'Tulsa', 'OK', 'Angela Brooks', 'Small Groups Pastor', 'growing', 'annual', 'active', 61, 5],
    ['First Light Church', 'Mesa', 'AZ', 'David Kim', 'Associate Pastor', 'small', 'monthly', 'active', 19, 3],
    ['Hope Harbor', 'Savannah', 'GA', 'Ruth Coleman', 'Ministry Lead', 'small', 'monthly', 'pilot', 12, 1],
    ['Living Waters', 'Fresno', 'CA', 'Samuel Ortiz', 'Pastor', 'growing', 'monthly', 'pilot', 30, 2],
    ['Bethel Assembly', 'Dayton', 'OH', 'Karen Wells', 'Administrator', 'large', 'monthly', 'suspended', 140, 6],
    ['Calvary Grace', 'Lexington', 'KY', 'Paul Turner', 'Elder', 'growing', 'monthly', 'active', 47, 4]];
  const FN = ['James', 'Mary', 'John', 'Patricia', 'Robert', 'Jennifer', 'Michael', 'Linda', 'William', 'Elizabeth', 'David', 'Barbara', 'Richard', 'Susan', 'Joseph', 'Jessica', 'Thomas', 'Sarah', 'Charles', 'Karen', 'Daniel', 'Nancy', 'Matthew', 'Lisa', 'Anthony', 'Betty', 'Mark', 'Grace', 'Paul', 'Ruth', 'Andrew', 'Naomi', 'Joshua', 'Esther', 'Kevin', 'Lydia'];
  const LN = ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis', 'Wilson', 'Anderson', 'Thomas', 'Taylor', 'Moore', 'Jackson', 'Martin', 'Lee', 'Thompson', 'White', 'Harris', 'Clark', 'Lewis', 'Walker', 'Hall', 'Young', 'King', 'Wright', 'Scott', 'Green', 'Baker', 'Adams'];
  const TABLES = ['Tuesday Table', 'Thursday Table', "Men's Morning", "Women's Evening", 'Young Adults', 'Couples', 'Sunday Breakfast', 'Seniors', 'Parents', 'Downtown', 'Northside', 'Workplace', 'Lunch Hour', 'Family Night', 'Prayer Circle', 'Saturday Table', 'Students', 'Neighbors', 'Westside', 'Early Risers'];

  function seed() {
    const today = ymd(new Date());
    let r = 7; const rnd = () => (r = (r * 9301 + 49297) % 233280) / 233280;
    const db = { version: 1, plans: JSON.parse(JSON.stringify(PLANS)), churches: [], subs: [], admins: [], invites: [], invoices: [], events: [], memberships: [], tables: [], participation: [], audit: [], outbox: [], processed: [], session: null, invSeq: 2001,
      settings: { platformName: 'The 144(P) Plan', support: 'support@144pplan.example', pilotDays: 90, enrollmentPolicy: 'approval', privacyThreshold: 5, graceDays: 14, provider: 'Stripe Billing', providerMode: 'Test mode · not connected', inviteTemplate: 'You have been invited to administer {church} on The 144(P) Plan. Use the secure link below to create your administrator account. The link expires in 7 days.', features: { tableLeader: false, churchRedemptions: false, churchReports: true } } };
    const ev = (type, churchId, date, extra) => db.events.push({ id: uid(), type, churchId, occurredAt: toUTC(date) + (9 + Math.floor(rnd() * 9)) * 36e5 + Math.floor(rnd() * 59) * 6e4, providerEventId: 'evt_test_' + uid(), ...(extra || {}) });
    SEED.forEach(([name, city, state, admin, title, planId, freq, status, count, monthsAgo], i) => {
      const id = 'ch_' + pad(i + 1) + uid().slice(0, 4), created = addDays(addMonths(today, -monthsAgo), -(i % 5)), slug = slugify(name), dom = slug.replace(/-/g, '') + '.org';
      const policy = i % 3 === 0 ? 'approval' : 'open';
      db.churches.push({ id, code: `144P-${1001 + i}`, slug, name, address: `${120 + i * 37} Main Street`, city, state, postal: String(29601 + i * 4111).slice(0, 5), website: 'www.' + dom, phone: '', contactEmail: `${admin.split(' ')[0].toLowerCase()}@${dom}`, createdAt: created, enrollmentPolicy: policy, features: { tableLeader: false, churchRedemptions: false } });
      ev('church.registered', id, created);
      const plan = PLANS.find(p => p.id === planId);
      let price = freq === 'monthly' ? plan.monthly : plan.annual;
      if (name === 'Grace Fellowship') price = 49;
      const pilot = status === 'pilot', wasPilot = pilot || i % 4 === 0;
      const sub = { id: 'sub_' + uid(), churchId: id, planId, freq, contractPrice: price, status, prevStatus: null, periodStart: created, periodEnd: null, pilotEnd: null, wasPilot, cancelAtPeriodEnd: false, providerCustomerId: 'cus_test_' + uid().slice(0, 8), providerSubId: 'sub_test_' + uid().slice(0, 8), includedPartners: null, discountPct: name === 'Calvary Grace' ? 10 : 0, card: `Card •••• ${1000 + Math.floor(rnd() * 8999)}`, createdAt: created };
      db.subs.push(sub);
      if (pilot) { sub.pilotEnd = addDays(created, 90); sub.periodEnd = sub.pilotEnd; ev('subscription.created', id, created, { planId, pilot: true }); }
      else {
        let start = created;
        if (wasPilot) { ev('subscription.created', id, created, { planId, pilot: true }); start = addMonths(created, 2); ev('pilot.converted', id, start, { planId }); }
        else ev('subscription.created', id, created, { planId });
        const step = freq === 'monthly' ? 1 : 12, stopAt = status === 'canceled' ? addMonths(today, -2) : today;
        const amt = Math.round(price * (1 - sub.discountPct / 100) * 100) / 100;
        for (let d = start; d <= stopAt; d = addMonths(d, step)) {
          const last = addMonths(d, step) > stopAt;
          const st = last && (status === 'past_due' || status === 'suspended') ? 'failed' : 'paid';
          db.invoices.push({ id: 'in_' + uid(), number: 'INV-' + (db.invSeq++), churchId: id, subId: sub.id, amount: amt, status: st, issuedAt: d, paidAt: st === 'paid' ? d : null, method: sub.card });
          ev(st === 'paid' ? 'invoice.paid' : 'invoice.payment_failed', id, d, { amount: amt });
          sub.periodStart = d; sub.periodEnd = addMonths(d, step);
        }
        if (status === 'canceled') { ev('subscription.canceled', id, stopAt); sub.periodEnd = stopAt; }
        if (status === 'suspended') { sub.prevStatus = 'past_due'; ev('subscription.suspended', id, addDays(sub.periodStart, 15)); }
        if (name === 'Kingdom Life Center') ev('plan.upgraded', id, addMonths(today, -3), { planId: 'large' });
      }
      // administrators / invitations
      if (pilot) {
        const inv = { id: 'inv_' + uid(), churchId: id, email: `${admin.split(' ')[0].toLowerCase()}@${dom}`, name: admin, title, tokenHash: null, expiresAt: addDays(today, 5), acceptedAt: null, createdAt: addDays(today, -2) };
        db.invites.push(inv);
        db.outbox.push({ id: uid(), to: inv.email, subject: `Administrator invitation · ${name}`, kind: 'admin_invite', inviteId: inv.id, token: null, at: Date.now() - 2 * 864e5 });
      } else db.admins.push({ id: 'adm_' + uid(), name: admin, email: `${admin.split(' ')[0].toLowerCase()}@${dom}`, title, churchId: id, role: 'church_admin', verifiedAt: toUTC(addDays(created, 1)), revokedAt: null, pw: null });
      // tables
      const nt = Math.max(1, Math.min(TABLES.length, Math.round(count / 22) + 1)), tids = [];
      for (let t = 0; t < nt; t++) { const tid = 'tbl_' + uid(); tids.push(tid); db.tables.push({ id: tid, churchId: id, name: TABLES[(t + i) % TABLES.length], leaderId: null, status: 'active', createdAt: created }); }
      // memberships (association only — no spiritual data)
      const span = Math.max(1, diffDays(created, today));
      for (let k = 0; k < count; k++) {
        const fn = FN[(k * 7 + i * 3) % FN.length], ln = LN[(k * 11 + i * 5) % LN.length];
        const joined = addDays(created, Math.floor(rnd() * span));
        const gone = status === 'canceled' || status === 'suspended';
        const lastActive = gone ? addDays(today, -(25 + Math.floor(rnd() * 40))) : rnd() < 0.9 ? addDays(today, -Math.floor(rnd() * 12)) : addDays(today, -(31 + Math.floor(rnd() * 30)));
        db.memberships.push({ id: 'mem_' + uid(), churchId: id, partnerRef: null, name: `${fn} ${ln}`, email: `${fn}.${ln}${k}`.toLowerCase() + '@example.com', tableId: tids[k % tids.length], status: policy === 'approval' && k < 2 && !gone ? 'pending' : 'verified', role: 'partner', joinedAt: joined < today ? joined : today, lastActive: lastActive > joined ? lastActive : joined });
      }
      // aggregate participation (computed server-side in production; never per-Partner)
      for (let w = 11; w >= 0; w--) {
        const week = addDays(today, -7 * w - ((new Date().getDay() + 6) % 7));
        if (week < created) continue;
        const base = status === 'canceled' && w < 8 ? 0 : count * (0.72 + 0.12 * Math.sin((w + i) / 2));
        const participants = Math.round(base * (w < 1 ? 0.7 : 1));
        db.participation.push({ churchId: id, week, participants, minutes: participants * (560 + ((w * 37 + i * 53) % 260)) });
      }
    });
    db.audit.push({ id: uid(), actor: 'system', org: null, action: 'seed.demo_data', resourceType: 'platform', resourceId: null, at: Date.now() });
    return db;
  }
  function load() { let db = null; try { db = JSON.parse(localStorage.getItem(AKEY)); } catch (e) {} if (!db || !db.version) { db = seed(); save(db); } return db; }
  function save(db) { try { localStorage.setItem(db && db.cloud ? AKEY + '-live' : AKEY, JSON.stringify(db)); } catch (e) {} }
  function loadLive() { try { const db = JSON.parse(localStorage.getItem(AKEY + '-live')); return db && db.cloud ? db : null; } catch (e) { return null; } }
  function clearLive() { try { localStorage.removeItem(AKEY + '-live'); } catch (e) {} }
  function reset() { const db = seed(); save(db); return db; }
  // ---------- live mode (Supabase) ----------
  const C = () => window.Cloud;
  const d10 = t => (t ? String(t).slice(0, 10) : null);
  const blankDb = () => { const db = seed(); ['churches', 'subs', 'admins', 'invites', 'invoices', 'events', 'memberships', 'tables', 'participation', 'audit', 'outbox', 'processed'].forEach(k => { db[k] = []; }); db.cloud = true; return db; };
  async function cloudLoad(roles) {
    const c = await C().sb(), ok = C().ok, platform = roles.some(r => r.role === 'platform_admin');
    const db = blankDb();
    const [plans, churches, subs, invoices, tables, admins] = await Promise.all([
      c.from('subscription_plans').select('*').then(ok), c.from('churches').select('*').order('name').then(ok), c.from('church_subscriptions').select('*').then(ok),
      c.from('invoices').select('*').order('issued_at').then(ok), c.from('tables').select('*').then(ok), c.rpc('church_admins').then(ok)]);
    db.plans = plans.map(p => ({ id: p.id, name: p.name, monthly: p.monthly_price == null ? null : Number(p.monthly_price), annual: p.annual_price == null ? null : Number(p.annual_price), limit: p.active_partner_limit, status: p.status, features: p.enabled_features || [], custom: p.monthly_price == null }));
    db.churches = churches.map(x => ({ id: x.id, code: x.code, slug: x.slug, name: x.name, address: x.address || '', city: x.city || '', state: x.state || '', postal: x.postal_code || '', website: x.website || '', phone: x.phone || '', contactEmail: x.contact_email || '', createdAt: d10(x.created_at), enrollmentPolicy: x.enrollment_policy, features: x.features || {} }));
    db.subs = subs.map(s => ({ id: s.id, churchId: s.church_id, planId: s.plan_id, freq: s.billing_frequency, contractPrice: Number(s.contract_price), status: s.status, prevStatus: null, periodStart: s.period_start, periodEnd: s.period_end, pilotEnd: s.pilot_end, wasPilot: !!s.pilot_end, cancelAtPeriodEnd: s.cancel_at_period_end, providerCustomerId: s.provider_customer_id || '', providerSubId: s.provider_subscription_id || '', includedPartners: s.included_partners, discountPct: Number(s.discount_pct || 0), card: '', createdAt: s.period_start }));
    db.invoices = invoices.map(i => ({ id: i.id, number: i.number || '', churchId: i.church_id, subId: (db.subs.find(s => s.churchId === i.church_id) || {}).id, amount: Number(i.amount), status: i.status, issuedAt: i.issued_at, paidAt: i.paid_at, method: '' }));
    db.tables = tables.map(t => ({ id: t.id, churchId: t.church_id, name: t.name, leaderId: t.leader_partner_id, status: t.status, createdAt: d10(t.created_at) }));
    db.admins = admins.map(a => ({ id: a.user_id, name: a.name || a.email, email: a.email, title: a.title || 'Administrator', churchId: a.church_id, role: 'church_admin', verifiedAt: C().ms(a.verified_at), revokedAt: C().ms(a.revoked_at), pw: null }));
    const members = await Promise.all(db.churches.map(ch => c.rpc('church_members', { cid: ch.id }).then(ok).then(rows => rows.map(m => ({ id: m.id, churchId: ch.id, partnerRef: m.partner_id, name: m.name, email: m.email, tableId: m.table_id, status: m.status, role: 'partner', joinedAt: m.joined_at, lastActive: m.last_active_at || m.joined_at })))));
    db.memberships = members.flat();
    if (platform) {
      const [part, inv, ev, aud, st] = await Promise.all([c.from('participation_weekly').select('*').then(ok), c.from('church_invitations').select('*').then(ok), c.from('subscription_events').select('*').then(ok), c.from('audit_logs').select('*').order('created_at').limit(500).then(ok), c.from('platform_settings').select('settings').maybeSingle().then(ok)]);
      db.participation = part.map(p => ({ churchId: p.church_id, week: p.week_start, participants: p.participants, minutes: p.minutes }));
      db.invites = inv.map(i => ({ id: i.id, churchId: i.church_id, email: i.invited_email, name: i.invited_name || '', title: i.invited_title || '', tokenHash: i.invitation_token_hash, expiresAt: d10(i.expires_at), acceptedAt: C().ms(i.accepted_at), createdAt: C().ms(i.created_at) }));
      db.events = ev.map(e => ({ id: e.id, type: e.event_type, churchId: e.church_id, occurredAt: C().ms(e.occurred_at), providerEventId: e.provider_event_id, ...(e.payload || {}) }));
      db.processed = ev.map(e => e.provider_event_id);
      db.audit = aud.map(a => ({ id: a.id, actor: a.actor_id ? 'user' : 'system', org: a.organization_id, action: a.action, resourceType: a.resource_type, resourceId: a.resource_id, at: C().ms(a.created_at) }));
      if (st && st.settings) Object.assign(db.settings, st.settings);
    } else {
      const parts = await Promise.all(db.churches.map(ch => c.rpc('church_participation', { cid: ch.id }).then(ok).then(rows => rows.map(r => ({ churchId: ch.id, week: r.week_start, participants: r.participants == null ? 1 : r.participants, minutes: r.hours == null ? 0 : Math.round(r.hours * 60) })))));
      db.participation = parts.flat();
    }
    db.settings.providerMode = 'Live database · billing provider not connected';
    return db;
  }
  // Give locally created rows real UUIDs before they are written
  function uuidify(db) {
    const isU = C().isUuid; let json = JSON.stringify(db); const map = {};
    ['churches', 'tables', 'subs', 'invites'].forEach(k => db[k].forEach(r => { if (!isU(r.id)) map[r.id] = crypto.randomUUID(); }));
    Object.entries(map).forEach(([a, b]) => { json = json.split(JSON.stringify(a)).join(JSON.stringify(b)); });
    return Object.keys(map).length ? JSON.parse(json) : db;
  }
  async function cloudSync(a, b) {
    const c = await C().sb(), ok = C().ok, J = JSON.stringify;
    const changed = k => { const old = Object.fromEntries((a[k] || []).map(r => [r.id, J(r)])); return b[k].filter(r => old[r.id] !== J(r)); };
    for (const x of changed('churches')) ok(await c.from('churches').upsert({ id: x.id, code: x.code, slug: x.slug, name: x.name, address: x.address || null, city: x.city || null, state: x.state || null, postal_code: x.postal || null, website: x.website || null, phone: x.phone || null, contact_email: x.contactEmail || null, enrollment_policy: x.enrollmentPolicy === 'open' ? 'open' : 'approval', features: x.features || {} }));
    for (const s of changed('subs')) ok(await c.from('church_subscriptions').upsert({ id: s.id, church_id: s.churchId, plan_id: s.planId, billing_frequency: s.freq, contract_price: s.contractPrice || 0, discount_pct: s.discountPct || 0, included_partners: s.includedPartners || null, status: s.status, period_start: s.periodStart || null, period_end: s.periodEnd || null, pilot_end: s.pilotEnd || null, cancel_at_period_end: !!s.cancelAtPeriodEnd }));
    for (const t of changed('tables')) ok(await c.from('tables').upsert({ id: t.id, church_id: t.churchId, name: t.name, leader_partner_id: C().isUuid(t.leaderId) ? t.leaderId : null, status: t.status || 'active' }));
    const keepT = new Set(b.tables.map(t => t.id));
    for (const t of a.tables.filter(t => !keepT.has(t.id))) ok(await c.from('tables').delete().eq('id', t.id));
    for (const m of changed('memberships')) if (C().isUuid(m.id)) ok(await c.from('memberships').update({ status: m.status, table_id: C().isUuid(m.tableId) ? m.tableId : null }).eq('id', m.id));
    for (const i of changed('invites')) ok(await c.from('church_invitations').upsert({ id: i.id, church_id: i.churchId, invited_email: i.email, invited_name: i.name || null, invited_title: i.title || null, invitation_token_hash: i.tokenHash, expires_at: new Date(i.expiresAt + 'T23:59:59').toISOString(), accepted_at: C().iso(i.acceptedAt) }));
    for (const p of changed('plans')) ok(await c.from('subscription_plans').update({ name: p.name, monthly_price: p.monthly, annual_price: p.annual, active_partner_limit: p.limit, enabled_features: p.features || [], status: p.status }).eq('id', p.id));
    if (J(a.settings) !== J(b.settings) && b.session && b.session.role === 'platform') { const { providerMode, ...rest } = b.settings; ok(await c.from('platform_settings').update({ settings: rest }).eq('id', 1)); }
  }
  async function cloudAdminSession(email, password) {
    await C().signIn(email, password);
    const roles = await C().rpc('my_admin_roles');
    if (!roles.length) { await C().signOut(); throw new Error('This account is not a verified administrator.'); }
    return roles;
  }

  window.AdminData = { AKEY, PLANS, load, loadLive, clearLive, save, reset, seed, cloudLoad, cloudSync, uuidify, cloudAdminSession, helpers: { pad, ymd, toUTC, fromUTC, addDays, diffDays, addMonths, slugify, uid, sha } };
})();
