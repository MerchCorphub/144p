-- 0033: Terms and Conditions and Privacy Policy, editable in Admin Panel › Settings.
-- Public pages terms.html and privacy.html read them. Placeholders filled in when shown:
--   {{support_email}} (Settings › support email), {{mailing_address}} (Settings › invoice mailing address),
--   {{effective_date}} (the date set when saving).
create table if not exists public.legal_docs (
  slug text primary key check (slug in ('terms', 'privacy')),
  title text not null, body text not null, effective_date date not null default current_date,
  version int not null default 1, updated_at timestamptz not null default now(), updated_by uuid
);
create table if not exists public.legal_doc_versions (
  id bigserial primary key, slug text not null, version int not null, title text not null, body text not null,
  effective_date date not null, saved_at timestamptz not null default now(), saved_by uuid
);
alter table public.legal_docs enable row level security;
alter table public.legal_doc_versions enable row level security;
revoke all on public.legal_docs, public.legal_doc_versions from anon, authenticated;

insert into public.legal_docs (slug, title, body, effective_date) values
  ('terms', 'Terms and Conditions', $legal$# Terms and Conditions

**Time4God Challenge · The 144(P) Plan**
Effective date: {{effective_date}}

These Terms and Conditions ("Terms") are a binding agreement between you and **Merch Corporation** ("Merch Corporation," "we," "us" or "our"), the company that owns and operates the Time4God Challenge app, The 144(P) Plan, time4god.app and the related websites, emails and services (together, the "Service").

**Please read Section 20 carefully. It requires most disputes to be settled by individual arbitration in Georgia, not in court, and it waives class actions and jury trials. You can opt out of arbitration within 30 days, as Section 20 explains.**

By creating an account, buying seats, claiming a book key, accepting a trial or guest invitation, registering a church or group, or otherwise using the Service, you agree to these Terms and to our [Privacy Policy](privacy.html). If you do not agree, do not use the Service.

## 1. What the Service is

The Service helps people give God a tithe of their time (about 2.4 hours a day) over a 12-week season. It includes:

- the digital edition of the book *What Will You Give Today?* by C.P. Parker, released week by week;
- tools to record time given to God ("deposits"), private notes and weekly reflections;
- churches, groups and leader tools for approving members, organizing groups and sending messages;
- friendly challenges between people, groups and churches, with scores and leaderboards;
- purchases of individual and church seats, guest seats, trial passes and book keys for readers of the printed book.

The Service is an encouragement and study tool. It is not a church, a ministry license, or a substitute for your own church, pastor or professional advice (see Section 14).

## 2. Who may use the Service

- You must be **at least 13 years old** to create an account. Children under 13 may not create accounts or give us personal information.
- If you are 13 to 17 (or under the age of majority where you live), you may use the Service only with the permission and supervision of a parent or legal guardian, who agrees to these Terms for you and is responsible for your use.
- If you register or manage a church, group or other organization, you confirm that you are authorized to act for it and to accept these Terms on its behalf. In that case "you" also means the organization.
- You may not use the Service if we have previously removed you from it, or if the law prohibits it.

## 3. Your account

- Give us true, current information, including your real first and last name. Church leaders rely on names to approve members.
- Keep your password private. You are responsible for everything done through your account. Tell us right away at {{support_email}} if you think someone else has used it.
- One person per account. Do not share, sell or transfer your account or your seat.
- We may refuse, suspend or close accounts that break these Terms, put others at risk, or harm the Service.

## 4. Types of membership

The Service shows one of these labels on each account. Features and access depend on the label.

- **Prospect:** a free account that has not bought or received a seat. Prospects can look around and read free sample content.
- **Member:** an account with an active paid seat (bought personally, provided by an approved church or group, or claimed with a book key).
- **Guest:** an account using a guest seat that a Member gave them (Section 7).
- **Trial:** an account using a free trial pass we sent (Section 8).

We may change what each label includes. We will not take away paid access you already have for the rest of its term, except as Sections 17 and 18 allow.

## 5. Prices, payment and taxes

- **One-year access.** Seats give access for one year from the date of purchase (or from activation, where stated). Seats do **not** renew automatically. When a seat ends, you may buy again at the price shown at that time.
- **Keep-going price.** Members whose seat is ending may be offered a "keep going" price, currently the then-current price minus a $5 discount. We may change or end this offer.
- **Church and group seats** are priced per seat in tiers, with a minimum purchase shown at checkout (currently 5 seats). Seats added later are priced at the tier for the new total and end on the same date as the existing seats.
- **Prices include tax** where we are required to collect it. Prices are in U.S. dollars and may change at any time; changes do not affect purchases already completed.
- **Payment processing.** Card payments are processed by Stripe. We do not see or store your full card number. Your payment is also subject to Stripe's terms.
- **Invoices.** Church and group orders of $20,000 or more may be paid by invoice. Invoices are due within the number of days stated on the invoice (currently 15) and may be paid online, by check or by wire as the invoice explains. **Seats on an invoice turn on only after we receive payment in full.** We may cancel an unpaid invoice after its due date. You are responsible for any bank or wire fees.
- **Payment problems.** If a payment is reversed, disputed or fails, we may suspend the related seats until it is resolved.

## 6. All sales are final

**All sales are final. We do not give refunds or credits** for seats, unused seats, partial years, seats a church never assigns, members a church removes, or seats that end because an account was closed for breaking these Terms. This includes card, invoice, check and wire payments. If you were charged in error (for example, a duplicate charge), contact us at {{support_email}} within 30 days and we will correct it. Nothing in this section limits any right you have under law that cannot be waived.

## 7. Guest seats ("give one")

- Each eligible purchase, and each eligible book-key claim, may include one guest seat that the buyer can give to one other person.
- A guest seat gives the full book for the time stated when it is given. **A guest cannot give guest seats.** Guests may buy their own seat, including any keep-going price offered.
- Guest seats have no cash value, cannot be sold or traded, and are not replaced if unused, lost or given to the wrong person. We may limit, change or end guest seats at any time, and may cancel guest seats obtained by fraud or abuse.

## 8. Trial passes

- We may, at our choice, invite people to try the Service free for a limited time (currently 14 days from acceptance).
- A trial pass is personal, has no cash value, and ends automatically. When it ends we will invite you to join at the then-current price; you are never charged unless you choose to buy.
- We may end or change trial passes at any time. Trial invitations are sent by email from us, or by text message from an administrator's own phone (Section 12).

## 9. Book keys for readers of the printed book

- Readers of the printed book may claim the app edition with the key printed in the book. To protect the book, we may ask a question that only someone holding the book can answer (for example, a word on a given page).
- One claim per account and per copy of the book, up to the limit set for each key. Keys have no cash value and may not be sold, posted publicly or shared beyond what the key allows.
- We may turn off a key, reject a claim or remove access claimed by guessing, sharing or other misuse.

## 10. Churches and groups

These terms apply to any church, independent group or other organization ("Organization") that registers on the Service, and to the people who manage it.

- **Approval.** We review every Organization before its members can join. We may approve, decline or later remove an Organization at our discretion. An Organization may buy seats before it is approved; if we decline it, we will work with it in good faith on the seats it paid for, but Section 6 still applies.
- **Authorized people.** The person who registers the Organization becomes its admin. Admins may name group leaders. We may also assign our own account managers. Each Organization is responsible for the people it gives leader access to and for what they do.
- **Approving members.** Admins and leaders decide who belongs to their Organization and should approve only real members. An approved member uses one of the Organization's seats while approved. Removing a member frees the seat for someone else but does not create a refund.
- **License scope.** Organization seats are for the Organization's own members, for use within its own ministry. They may not be resold, rented, shared with other organizations or used to run a competing service.
- **What leaders can see.** Admins, leaders and our account managers can see members' names, email addresses, membership status, group, and participation information needed to run the Organization and its challenges. **They cannot see members' private notes or weekly reflections.** Our [Privacy Policy](privacy.html) explains this in detail.
- **Leader responsibilities.** Leaders must use member information only to serve their members, keep it confidential, and follow the law, including laws about contacting people. Messages leaders send through the Service must be appropriate, truthful and related to the Organization's ministry.
- **Billing details.** The Organization must give accurate billing information. Invoices and receipts go to the billing email it provides.

## 11. Challenges, scores and leaderboards

- Time is **self-reported**. The Service works on the honor system and is meant to encourage, not to judge anyone's faith.
- When you join a challenge or belong to an Organization that does, your name and your totals may be shown to the other participants and on leaderboards. Your private notes and reflections are never shown.
- Do not enter false time or manipulate results. We may correct, hide or remove scores, entries or challenges at our discretion, and our decision is final.
- Unless we say otherwise in writing, challenges have **no prizes** and are not contests, sweepstakes or games of chance.

## 12. Emails, notifications and text messages

- **Service emails.** We send emails needed to run the Service, such as account, approval, payment, invoice, receipt and security messages. You cannot opt out of these while you have an account.
- **Reminders and leader messages.** You may receive reminder emails, push notifications on your device, and messages from your church or group leaders. You can turn reminders and push notifications off in the app or on your device.
- **Text messages.** The Service does not send text messages itself. Some features open your own phone's messaging app with a suggested invitation so **you** can send it. When you do, you are the sender, and you are responsible for having permission to text that person and for following the law, including the Telephone Consumer Protection Act. Standard message and data rates from your carrier may apply.
- **Invitations by email.** When you or an administrator enter someone's email to invite them, you confirm that you know the person and have a reasonable basis to contact them.

## 13. Acceptable use

You agree not to:

- break any law or anyone's rights, including privacy and intellectual property rights;
- harass, threaten, shame or pressure anyone, including about their faith, giving or participation;
- post or send content that is hateful, sexual, violent, defamatory, deceptive or spam;
- impersonate a person, church or leader, or claim authority you do not have;
- copy, scrape, record, screenshot for distribution, or share the book or other paid content;
- share accounts, seats, keys, guest seats or trial links in ways these Terms do not allow;
- probe, attack, overload or interfere with the Service or its security, or use bots or automated tools to access it;
- reverse engineer the Service except where the law allows; or
- use the Service to build or market a competing product.

## 14. Spiritual content and no professional advice

The Service offers Christian encouragement, Scripture and study material. It does not provide medical, mental health, financial, legal or pastoral counseling advice, and it does not create a pastoral or counseling relationship. Decisions about your time, work, health, family and finances are yours. Talk with a qualified professional or your own pastor about your situation. If you are in crisis or in danger, contact local emergency services right away (in the U.S., call or text 988 for the Suicide and Crisis Lifeline, or 911).

## 15. Your content

- You keep ownership of what you put into the Service, such as notes, reflections, messages, names of groups and challenge entries ("Your Content").
- You give us a non-exclusive, worldwide, royalty-free license to host, store, copy, display and process Your Content only as needed to operate, protect and improve the Service and as our Privacy Policy describes. This license ends when Your Content is deleted from the Service, except for backups kept for a limited time, content others have already received (such as a message you sent) and records we must keep by law.
- You are responsible for Your Content and confirm you have the right to share it. We do not have to review it, but we may remove content that breaks these Terms or the law.

## 16. Our content and intellectual property

- The Service, the book *What Will You Give Today?*, the names Time4God Challenge and The 144(P) Plan, and all text, design, graphics and software are owned by Merch Corporation, C.P. Parker or our licensors and are protected by copyright, trademark and other laws.
- We give you a personal, limited, non-exclusive, non-transferable, revocable license to use the Service and read the content available to your account, for your own non-commercial use (or, for an Organization, for its own ministry), during your access period. All other rights are reserved.
- Scripture quotations remain the property of their copyright holders and are used under their terms.
- **Copyright concerns.** If you believe content on the Service infringes your copyright, email {{support_email}} with your contact details, a description of the work and the material, its location on the Service, a statement of good-faith belief, a statement under penalty of perjury that your notice is accurate and that you are authorized to act, and your signature. We may remove material and close the accounts of repeat infringers.

## 17. Changes to the Service

We may add, change, suspend or stop any part of the Service at any time, including features, content, seasons and prices. We will try to give reasonable notice of changes that materially reduce what you paid for. If we permanently stop the entire Service before paid access ends, we will tell you how we will handle it, which may include continued access to the book or another reasonable remedy we choose.

## 18. Suspension and termination

- You may stop using the Service at any time and may ask us to delete your account at {{support_email}}. Closing your account ends any seat, guest seat or trial on it without refund.
- We may suspend or close your account, an Organization's account, or any seats, with or without notice, if we reasonably believe you broke these Terms, created risk or legal exposure for us or others, did not pay, or misused the Service.
- Sections that by their nature should survive (including 5, 6, 13 to 16, and 19 to 22) survive after termination.

## 19. Disclaimers and limits on our responsibility

**Disclaimer.** THE SERVICE AND ALL CONTENT ARE PROVIDED "AS IS" AND "AS AVAILABLE." TO THE FULLEST EXTENT THE LAW ALLOWS, WE DISCLAIM ALL WARRANTIES, EXPRESS OR IMPLIED, INCLUDING MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. WE DO NOT PROMISE THAT THE SERVICE WILL BE UNINTERRUPTED, ERROR-FREE OR SECURE, THAT DATA WILL NEVER BE LOST, OR ANY PARTICULAR SPIRITUAL, PERSONAL OR FINANCIAL RESULT.

**Limitation of liability.** TO THE FULLEST EXTENT THE LAW ALLOWS: (a) WE ARE NOT LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, EXEMPLARY OR PUNITIVE DAMAGES, OR FOR LOST PROFITS, REVENUE, DATA OR GOODWILL, EVEN IF WE WERE TOLD THEY WERE POSSIBLE; AND (b) OUR TOTAL LIABILITY FOR ALL CLAIMS RELATING TO THE SERVICE OR THESE TERMS IS LIMITED TO THE GREATER OF THE AMOUNT YOU PAID US IN THE 12 MONTHS BEFORE THE EVENT GIVING RISE TO THE CLAIM, OR ONE HUNDRED U.S. DOLLARS ($100). These limits apply to Merch Corporation and its owners, officers, employees, agents, authors and licensors, and apply even if a remedy fails of its essential purpose. Some places do not allow certain limits, so some of them may not apply to you.

**Things outside our control.** We are not responsible for the actions of churches, leaders, other users or third-party services (such as Stripe, email and hosting providers, app stores or your phone carrier), or for delays or failures caused by events beyond our reasonable control.

**Indemnity.** You will defend, indemnify and hold harmless Merch Corporation and its owners, officers, employees, agents, authors and licensors from any claims, losses, damages, liabilities and costs (including reasonable attorneys' fees) arising from Your Content, your misuse of the Service, your violation of these Terms or the law, messages or invitations you send, or, for Organizations and leaders, how you manage your members and their information.

## 20. Dispute resolution and arbitration

**Talk to us first.** Before starting a claim, email {{support_email}} with a description of the problem and the relief you want. We will try in good faith to resolve it within 60 days.

**Binding individual arbitration.** If we cannot resolve it, you and Merch Corporation agree that any dispute, claim or controversy arising out of or relating to the Service or these Terms (including their validity, scope or enforceability) will be settled by **binding individual arbitration**, not in court, except as listed below. The Federal Arbitration Act governs this section.

- The arbitration will be administered by the American Arbitration Association ("AAA") under its Consumer Arbitration Rules (or, for Organizations, its Commercial Arbitration Rules), before a single arbitrator.
- The arbitration will take place in the **State of Georgia**, in or near Atlanta, unless you and we agree otherwise. For claims under $10,000, you may choose to proceed by documents only or by video or phone hearing.
- Fees are paid as the AAA rules provide. The arbitrator may award the same individual relief a court could, but only for the individual party seeking it.

**Exceptions.** Either party may bring an individual claim in small claims court if it qualifies, and either party may ask a court for an injunction to stop infringement or misuse of intellectual property or unauthorized access to the Service.

**Class action and jury trial waiver.** YOU AND WE EACH AGREE TO BRING CLAIMS ONLY IN AN INDIVIDUAL CAPACITY, AND NOT AS A PLAINTIFF OR CLASS MEMBER IN ANY CLASS, COLLECTIVE, CONSOLIDATED OR REPRESENTATIVE PROCEEDING. YOU AND WE EACH WAIVE THE RIGHT TO A JURY TRIAL. If this waiver is found unenforceable for a claim, that claim will be decided in court, not arbitration, and the rest of this section still applies.

**Time limit.** To the extent the law allows, any claim must be brought within one year after it arises, or it is permanently barred.

**30-day opt-out.** You may opt out of arbitration by emailing {{support_email}} within 30 days after you first accept these Terms, with your name, account email and a clear statement that you opt out of arbitration. Opting out does not affect the rest of these Terms.

**Court venue.** For any dispute not subject to arbitration, you and we agree to the exclusive jurisdiction of the state and federal courts located in the State of Georgia.

## 21. Governing law

These Terms are governed by the laws of the State of Georgia, U.S.A., and applicable federal law, without regard to conflict-of-law rules.

## 22. General

- **Changes to these Terms.** We may update these Terms. We will post the new version with a new effective date and, for material changes, give notice in the app or by email. Changes apply from the effective date; if you keep using the Service after that, you accept them. Changes to Section 20 do not apply to disputes already filed.
- **Entire agreement.** These Terms, the Privacy Policy, and any invoice or checkout terms for a purchase are the entire agreement between you and us about the Service. If an invoice and these Terms conflict, these Terms control unless the invoice says otherwise.
- **Severability and waiver.** If any part of these Terms is unenforceable, the rest stays in effect. Our failure to enforce a term is not a waiver.
- **Assignment.** You may not transfer these Terms or your account. We may transfer them in connection with a merger, sale or reorganization.
- **Electronic notices.** You agree that we may give you notices electronically, by email or in the app, and that these satisfy any written-notice requirement.
- **No third-party beneficiaries,** except as Section 19 provides.

## 23. Contact us

Merch Corporation
{{mailing_address}}
Email: {{support_email}}
$legal$, '2026-11-23'),
  ('privacy', 'Privacy Policy', $legal$# Privacy Policy

**Time4God Challenge · The 144(P) Plan**
Effective date: {{effective_date}}

This Privacy Policy explains how **Merch Corporation** ("we," "us" or "our") collects, uses, shares and protects personal information when you use the Time4God Challenge app, The 144(P) Plan, time4god.app and related services (the "Service"). It is part of our [Terms and Conditions](terms.html).

**The short version:** we collect what we need to run the Service. We do not sell your personal information, we do not show ads, and we do not share your information with advertisers. Your private notes and weekly reflections are never shown to anyone else, including your church or group leaders.

## 1. Information you give us

- **Account details:** first and last name, email address, password (stored by our sign-in provider in protected, hashed form; we cannot see it), time zone and your giving plan.
- **Church or group membership:** the church or group you ask to join, its code, your status (waiting, approved or removed), the group you are placed in, and any leader roles.
- **Your time and reflections:** time you record ("deposits"), its category, date and time, timer activity, optional private notes, and weekly reflections.
- **Challenges:** challenges you create or join and the people or groups involved.
- **Messages:** messages leaders send to members through the Service, and messages you send to us.
- **Purchases:** what you bought, amount, date, seats and status. **Card details are collected and processed by Stripe; we never receive your full card number.**
- **Church and group registration and billing:** organization name, street address, city, state, ZIP, phone, website, billing contact name and billing email, and the requester's role and notes.
- **Book keys:** the key you enter and the answer to the book check question.
- **Invitations:** when you or an administrator invite someone (for example, a guest seat or trial pass), the name, email address and note entered for that person.
- **Support:** what you tell us when you contact us.

## 2. Information collected automatically

- **Device and app data:** the settings the app saves on your device (such as your sign-in session, your place in the book and the last church you viewed), and cached copies of app files so the app works offline.
- **Push notifications:** if you turn them on, a push token from your browser or device that lets us send you reminders.
- **Logs:** our hosting and database providers record technical information such as IP address, browser type, pages requested and error details, to keep the Service secure and working.
- **Fonts:** the app loads fonts from Google Fonts, which receives your IP address and browser information when the fonts load.

We do not use advertising cookies, ad trackers or third-party analytics, and we do not collect your precise location, contacts, photos, camera or microphone.

## 3. Sensitive information

Belonging to a church, taking part in a faith study or recording time spent in prayer can reveal your religious beliefs. We treat this information with extra care: we use it only to provide the Service to you, share it only as this policy describes, and never sell it or use it for advertising. You choose whether to join a church or group, and you may leave at any time.

## 4. How we use information

- to create and run your account, give you access to the book, and keep your records;
- to let churches and groups approve members, organize groups, send messages and run challenges;
- to process purchases, seats, guest seats, trial passes, book keys, invoices and receipts;
- to send service emails, reminders and push notifications you have turned on;
- to provide support, answer questions and send important notices about the Service or these policies;
- to prevent fraud and misuse, protect the Service and enforce our Terms;
- to understand, fix and improve the Service using our own records and summaries that do not identify you;
- to meet legal, tax and accounting requirements.

## 5. Who can see your information in the Service

- **Your church or group leaders** (admins, group leaders and our account managers assigned to that church) can see your name, email address, membership status, group, join date, recent activity, and participation used for group and church totals and challenges. **They cannot see your private notes or weekly reflections.**
- **Challenge participants** can see your name and your totals for that challenge, and leaderboards may show names and totals.
- **People you choose** to share with (where the app lets you share a summary) see only what you choose to share.
- **Platform administrators** at Merch Corporation can see account, membership, purchase and invoice information to run the Service and help you.

## 6. How we share information

We do **not** sell or rent personal information, and we do not share it for targeted advertising. We share it only:

- **with service providers** who run parts of the Service for us and may use it only for that purpose, including:
  - Supabase (database, sign-in, file storage and server functions),
  - Stripe (payments, invoices and fraud prevention),
  - Resend (sending email),
  - GitHub Pages (hosting the website),
  - Google Fonts (fonts), and
  - Apple, Google, Microsoft or Mozilla push services (delivering push notifications you turn on);
- **with your church or group**, as described in Section 5;
- **with people you invite**, when an invitation you or an administrator create is sent to them;
- **for legal reasons**, when we believe in good faith it is required by law, subpoena or court order, or needed to protect the rights, property or safety of you, others or Merch Corporation;
- **in a business transfer**, such as a merger, sale or reorganization, where the new owner must honor this policy;
- **with your consent** or at your direction.

## 7. Text messages and invitations

The Service does not send text messages itself. Some features open your own phone's messaging app with a suggested invitation, so the message goes from your phone and is covered by your carrier's and phone maker's privacy terms. Email invitations entered in the Service are sent by us through our email provider, and we keep the invitee's name and email to manage the invitation.

## 8. How long we keep information

We keep personal information while your account is open and as long as needed to provide the Service. After you ask us to delete your account, we delete or de-identify your personal information within a reasonable time, except:

- purchase, invoice and payment records, which we keep as long as tax and accounting laws require (generally at least 7 years);
- information we must keep to resolve disputes, prevent fraud or meet legal obligations; and
- copies in backups, which are overwritten over time.

Church and group records (such as invoices and seat history) belong to the organization's account and are kept while it remains active and as the law requires.

## 9. Your choices and rights

- **Access and correction:** you can see and update your name in the app (More › My Account). To change your email or get a copy of your information, email {{support_email}}.
- **Deletion:** you can ask us to delete your account and personal information by emailing {{support_email}}.
- **Leaving a church or group:** you may leave, or ask your leader to remove you, at any time.
- **Notifications:** turn reminders and push notifications on or off in the app or your device settings. Service emails (such as receipts and security notices) continue while you have an account.
- **State privacy rights:** depending on where you live (for example, California, Colorado, Connecticut, Virginia or other states with privacy laws), you may have rights to know, access, correct, delete or move your information, and to opt out of sale, sharing for targeted advertising, or profiling. We do not sell or share information for targeted advertising. To use your rights, email {{support_email}}. We will verify your request using your account email, and you may use an authorized agent where the law allows. We will not treat you differently for using your rights. If we deny your request, you may appeal by replying to our decision.
- **Do Not Track:** we do not track you across other websites, so we do not change our practices in response to Do Not Track signals.

## 10. Children

The Service is not for children under 13, and we do not knowingly collect personal information from them. Teens 13 to 17 may use the Service only with a parent's or guardian's permission. If you believe a child under 13 has given us information, email {{support_email}} and we will delete it.

## 11. Security

We protect information with measures such as encrypted connections (HTTPS), access controls that limit each person to the records they are allowed to see, hashed passwords, private file storage, and separate storage for private notes. No system is perfectly secure, so we cannot guarantee security. Keep your password private and tell us right away if you think your account has been misused. If a data breach affects you, we will notify you as the law requires.

## 12. Where information is stored

The Service is operated from the United States, and information is stored and processed in the United States and wherever our service providers operate. If you use the Service from outside the United States, you agree to this transfer.

## 13. Changes to this policy

We may update this Privacy Policy. We will post the new version with a new effective date and, for material changes, give notice in the app or by email before they take effect.

## 14. Contact us

Merch Corporation
{{mailing_address}}
Email: {{support_email}}
$legal$, '2026-11-23')
on conflict (slug) do nothing;
insert into public.legal_doc_versions (slug, version, title, body, effective_date)
select slug, version, title, body, effective_date from public.legal_docs d
where not exists (select 1 from public.legal_doc_versions v where v.slug = d.slug);

-- Anyone (signed in or not) can read the published text, with placeholders filled in
create or replace function public.public_legal(p_slug text) returns json
language sql stable security definer set search_path = public, private as $$
  select json_build_object('slug', d.slug, 'title', d.title, 'version', d.version, 'effective_date', d.effective_date, 'updated_at', d.updated_at,
    'body', replace(replace(replace(d.body,
      '{{support_email}}', coalesce(private.setting('support_email'), 'support@time4god.app')),
      '{{mailing_address}}', coalesce(replace(private.setting('invoice_address'), E'\n', ', '), 'Georgia, United States')),
      '{{effective_date}}', to_char(d.effective_date, 'FMMonth FMDD, YYYY')))
  from legal_docs d where d.slug = p_slug $$;

create or replace function public.admin_legal_docs() returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can edit legal pages.'; end if;
  return (select json_agg(json_build_object('slug', d.slug, 'title', d.title, 'body', d.body, 'effective_date', d.effective_date, 'version', d.version,
      'updated_at', d.updated_at, 'versions', (select count(*) from legal_doc_versions v where v.slug = d.slug)) order by d.slug desc) from legal_docs d);
end $$;

-- Saving keeps every earlier version, so nothing is ever lost
create or replace function public.admin_save_legal(p_slug text, p_title text, p_body text, p_effective date) returns json
language plpgsql security definer set search_path = public, private as $$
declare d legal_docs;
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can edit legal pages.'; end if;
  if coalesce(length(trim(p_body)), 0) < 200 then raise exception 'That text looks too short. Nothing was saved.'; end if;
  update legal_docs set title = coalesce(nullif(trim(p_title), ''), title), body = p_body, effective_date = coalesce(p_effective, current_date),
    version = version + 1, updated_at = now(), updated_by = auth.uid()
  where slug = p_slug returning * into d;
  if d.slug is null then raise exception 'Unknown page.'; end if;
  insert into legal_doc_versions (slug, version, title, body, effective_date, saved_by) values (d.slug, d.version, d.title, d.body, d.effective_date, auth.uid());
  return json_build_object('version', d.version, 'effective_date', d.effective_date);
end $$;

create or replace function public.admin_legal_versions(p_slug text) returns json
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_platform_admin() then raise exception 'Only the platform admin can see this.'; end if;
  return (select coalesce(json_agg(json_build_object('id', v.id, 'version', v.version, 'effective_date', v.effective_date, 'saved_at', v.saved_at, 'body', v.body) order by v.version desc), '[]'::json)
    from legal_doc_versions v where v.slug = p_slug);
end $$;

revoke execute on function public.public_legal(text), public.admin_legal_docs(), public.admin_save_legal(text, text, text, date), public.admin_legal_versions(text) from public;
grant execute on function public.public_legal(text) to anon, authenticated;
grant execute on function public.admin_legal_docs(), public.admin_save_legal(text, text, text, date), public.admin_legal_versions(text) to authenticated;
