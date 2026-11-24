Live at **https://time4god.app** (custom domain; merchcorphub.github.io/144p forwards there).

repo: MerchCorphub/144p
branch: main

## Last sync
date: 2026-11-18T01:30:00Z
### Updated in this project
- Live database 144p (hevkjegnogadwybbmwjx): migrations 0001, 0002 and 0003 applied on 2026-11-18; 0004 (church admins assigned by the platform admin) applied the same day (book reader, seasons, admin-set license prices, church licenses, individual seats, group-leader approvals with seat limits)
- New page: reset.html (forgot password, set a new password)
- New pages: read.html (member book reader + join by church code), leader.html (approvals, prices, licenses, churches, season, book upload)
- Partner app More menu links to the new pages

## Screen map
| Screen | Repo files |
|---|---|
| Partner app (all screens) — opens at time4god.app/ | index.html, cloud.js (144P-Plan-v2.dc.html forwards to it for old links) |
| Book reader + join church | read.html, cloud.js |
| Time4God Challenge (send by text/email, accept, scoreboards) | challenges.html, cloud.js |
| Admin Panel (platform admin) | admin.html → leader.html?panel=admin |
| Leader Console (church admins, group leaders: approvals, groups) | leader.html, book-import.js, cloud.js |
| Old admin page (now redirects to admin.html) | 144P-Admin.dc.html |
| PWA | manifest.json, sw.js, icon-192.png, icon-512.png, apple-touch-icon.png |
| Database | supabase/migrations/0001_init.sql, 0002_harden_and_rpcs.sql, 0003_book_licenses_approvals.sql, 0004_church_admins.sql, 0005_book_hidden_sections.sql, 0006_challenges.sql, 0006b_challenges_null_safety.sql, 0007_groups.sql, 0008_payments.sql, 0009_email_notifications.sql, 0010_reminders_messages.sql, 0011_book_keys.sql |

## Payments (Stripe)
- Server function `supabase/functions/stripe-pay` (deployed on the 144p Supabase project). Needs the secret `STRIPE_SECRET_KEY` (Supabase › Edge Functions › Secrets). Use an `sk_test_` key for testing, then the `sk_live_` key to go live.
- Buyers pay on Stripe Checkout and come back to the page they left; the page confirms the payment with Stripe and turns the seat or license on. Prices come from Admin Panel › Prices. One-time payments that last one year; church upgrades pay the difference and keep the end date. Prices include tax; all sales final.

## Email notifications (Resend)
- Database triggers queue emails in `email_outbox`; a one-minute cron job wakes `supabase/functions/send-emails`, which sends through Resend. Needs the secret `RESEND_API_KEY`; optional `EMAIL_FROM` (default `Time4God Challenge <notifications@time4god.app>`) and `EMAIL_REPLY_TO`.
- Church admins and group leaders: each new join request for their church. Platform admins: new accounts, join requests, payments, new churches. Everyone can turn these off in the Leader Console (Approvals › "Email me about new members").

## Daily reminders and leader messages
- Members turn on **Daily reminder** (phone/desktop notification) and/or **Email reminder** in the app's Reminders screen and pick a time. A cron job every 5 minutes queues each member's reminder at their time in their time zone: yesterday's minutes, streak, this week's chapter, challenge standing.
- Phone notifications: `supabase/functions/send-push` (Web Push with VAPID; keys in Supabase Vault). Emails: `send-emails` (Resend).
- Leader Console › Messages: church admins message the whole church or any group; group leaders message their own group (5 per church per day). Members see messages on the Time4God Challenge page under "From your church".

## App edition for print readers (book keys)
- The printed book carries a book key and the address time4god.app/redeem (`redeem.html`).
- Each reader gets a different check: a random printed page and a word on it; they type the word that comes next. Correct answer → free 1-year app seat; one claim per account; 3 tries per question, 6 questions an hour.
- Admin Panel › Book keys: upload the print interior PDF (`print-import.js` reads it in the browser with pdf.js, keyed by the printed page numbers, without running heads/footers), manage keys (on/off, claim limit, end date), and see claims.

## Leader sign-up
- time4god.app/leaders (`leaders.html`): seat-pack prices (live), how it works, and two paths:
  - Church leader → registers a church (pending until the platform admin approves in Admin Panel › Churches; requester becomes church admin).
  - Group leader → inside a church in the app (church code + group name; the church admin approves in Leader Console › Groups) or an independent group (approved like a church).
- App welcome screen: "I'm joining as: An individual · A group leader · A church leader". Leaders return to the leaders page after creating an account or signing in.

## Give one (guest seats)
- Every paid individual purchase (including "keep going") includes one guest seat (`guest_passes`, migration 0016). Unlocking the app with a printed-book key adds one too, once per reader per key (0016b).
- Sending a person challenge needs the study book. The first person who accepts gets the study book through the challenge's end date, using the sender's guest seat.
- Guests can't send person challenges. From the day they accept until 30 days after their challenge ends, they can buy their own year at the current individual price minus $5 (`keep_going` checkout).
- Admin Panel › Dashboard shows guest seats given, used, reading now, and kept going.

## Per-seat pricing (churches and groups)
- Church rows in `license_plans` are price levels (migration 0017): `min_seats`–`seat_limit` seats in total, `price` = price per seat. Smallest purchase = lowest `min_seats` (5).
- Leader Console › Buy seats: the leader types a number; total = seats × the rate for their total. Adding seats later charges the added seats at the rate for the new total, same end date.
- `stripe_prepare(..., p_seats)`; the stripe-pay function passes `seats` from the page.

## Pay by invoice ($20,000 and up)
- Leader Console › Buy seats: at $20,000+ the leader can choose "Send me an invoice" or pay by card. stripe-pay `invoice` action creates a Stripe customer (saved on the church), a 15-day invoice (bank transfer/wire, ACH or card) and emails it (migration 0018).
- Seats turn on only when Stripe reports the invoice paid. Checked every 15 minutes (cron `sync-invoices` → stripe-pay with x-notify-token) and when the church admin opens the Leader Console. Voided invoices close.
- One open invoice per church at a time. Pete gets an email when an invoice is sent and when it's paid. Admin Panel › Payments lists invoices; Dashboard shows invoices waiting and past due.

## Email settings
- Admin Panel › Settings (migration 0019, table `app_settings`): admin notification email(s), reply-to email, and support email. Blank admin email = each platform admin's sign-in email.
- send-emails reads reply-to from settings (the EMAIL_REPLY_TO secret is only a fallback). The support email shows on Help & Support, the study book page and the leaders page (`public_contact`).

## Roles (migration 0020)
- Owner (app_settings `owner_user_id`, Pete): Admin Panel › Roles to add/remove admins and account managers and assign churches to account managers.
- Admins (`platform_admin`): the whole Admin Panel except Roles.
- Account managers (`account_manager`, one role row with no church plus one row per assigned church): `private.is_church_admin` returns true for their churches, so they act as church admin there; they can also approve those churches' requests, assign church admins, and set licenses (RLS `clic_am_*`). Their panel: My churches (`am_overview`), Churches, Licenses, plus church tools. No prices, season, book, book keys, settings, dashboard or payments.
- Account managers get a Bcc copy of their churches' new-member and group-leader-request emails (0021, `email_outbox.bcc`); if a church has no leader to email yet, they get it directly.

## Members (Admin Panel)
- Waiting for approval (migration 0023, `admin_pending_members`): every pending join request across churches, approve/decline (single or bulk, grouped per church through approve_memberships / decline_memberships so seat limits apply).
- Admin Panel › No church (migration 0022): accounts with no pending or approved church membership — study book status, time logged, past church — with search, filters, and Add to church (single or bulk). `admin_add_to_church` adds them as approved members and emails them (the church's leaders get the usual "joined" email).

## Member categories (migration 0025)
- `private.member_category(pid)`: **member** (paid: own seat incl. book key, approved in a church with active seats, or leader of a licensed church), **guest** (active guest seat from a challenge), **prospect** (free, not paid; includes guests whose challenge ended).
- Shown in Admin Panel › All members (`admin_all_members`, search + filter), on No church rows, as Dashboard counts, and in the app's My Account (Membership card, from `my_access.category`).

## Trial passes (migration 0027)
- Admin Panel › All members › Trial passes: admins email invitations (`admin_create_trials`); link `access.html?trial=CODE`. Free days (default 14) start when accepted (`trial_claim`); unused invites expire after 30 days; one trial per person; resend/cancel/end trial.
- New category **trial** (Member > Guest > Trial > Prospect); study book unlocked while active. Daily job `trial-reminders` emails 2 days before the end and after it ends, asking them to join at the current individual price.

## Church sign-up and Time4God invoices (Nov 2026)

**Sign-up (church-signup.html)** — four steps with a progress bar: 1 Account → 2 Register (church or independent group, street address, billing contact and billing email) → 3 Seats (live price per seat and total) → 4 Checkout. Checkout offers **Pay now by card** (Stripe Checkout) or **Pay by invoice** (only for orders of $20,000 or more). The person can pay while the church waits for approval; members can join only after Pete approves. "Church leaders" buttons in the app now open this page. The page picks up where the person left off (`my_church_signup`).

**Invoices** — every church purchase gets a Time4God invoice document (`invoice_docs`, numbered T4G-YYYY-####):
- card purchase → a PAID invoice (receipt)
- invoice purchase ($20,000+) → an OPEN invoice with three ways to pay: online (Stripe pay link), mail a check, or wire
- Admin Panel › Licenses › Create invoice → an invoice by hand for any number of seats

The `invoice-pdf` function draws the PDF (logo, bill-to, seats × price, how to pay, terms), stores it in the private `invoices` bucket, and emails it to the billing email as an attachment (`send-emails` attaches it). Stripe no longer sends its own invoice email; it only provides the online pay link. Saving invoice details in Settings redraws open invoices.

**Admin Panel › Licenses** — tiles for Waiting for approval / Waiting for payment / Paid and active / No seats yet. Each church card shows approval (with Approve/Decline), seats used, and its invoices with PDF, Email again, Mark paid (check, wire or other, with a reference) and Cancel. "Set a license by hand" is still there, folded away.

**Admin Panel › Settings › What prints on invoices** — payable-to name, mailing address for checks, wire instructions, terms. Pete types bank details here himself.

Migrations 0029–0032. Edge functions: invoice-pdf (new), stripe-pay (mark_paid, void_invoice; finalize-only invoices), send-emails (attachments).

## Terms and Conditions and Privacy Policy (Nov 2026)

- Public pages: `terms.html` and `privacy.html` (same file; `legal.js` turns the simple Markdown into HTML). They read the live text from the database (`public_legal`) and fall back to `legal/terms.md` / `legal/privacy.md` shipped with the site.
- Edit in **Admin Panel › Settings › Terms and Privacy Policy**: edit/preview, effective date, Save and publish, earlier versions (every save kept in `legal_doc_versions`).
- Placeholders filled in when shown: `{{support_email}}` (Settings support email), `{{mailing_address}}` (Settings invoice mailing address), `{{effective_date}}`.
- Linked from the account sign-up checkbox, app footer, church sign-up checkout, individual checkout and the Leader Console buy box.
- Drafted from a review of comparable faith apps (YouVersion, Hallow, Glorify, RightNow Media): Merch Corporation as owner, 13+ (under 18 with a parent), Georgia law, individual AAA arbitration in Georgia with a 30-day opt-out and class-action waiver, all sales final, liability cap. Have an attorney review before relying on them.

## Family teen accounts and 4 guest seats a year (Nov 2026)

- Any paid member (own seat, book key, church seat or church leader) can link up to 2 teens (13–17), free. Parent adds them at access.html › Family (name, optional email, parent/guardian confirmation); the teen accepts at `family.html?code=…` with their own account and confirms age. Email invite is sent if an email is given; parents can also copy the link or text it from their phone.
- Teens are Members (paid by "family"); access lasts while the parent's own paid access lasts. Parents see the teen's time, notes, reflections and challenges (`family_teen_view`). Teens can't add teens or give guest seats.
- Guest seats: members with their own seat can give up to 4 in any 12 months (`guest_seats_left` counts seats used in the last year; a guest pass is created when a challenge is accepted).
- Sign-up screen tells parents about teen accounts. Terms (new Section 7A) and Privacy Policy updated to version 2.
- Migration 0034.

## Challenge a member by phone (Nov 2026)

- Members may add an optional mobile number in My Account (`set_my_phone`, stored as `partners.phone` / `phone_norm`). Never shown to others; the app doesn't send texts.
- Challenge someone › A person › "To a member, by phone number": `challenge_member_by_phone` creates a person challenge addressed to that member only (`challenges.target_partner_id`), emails them, and shows it at the top of their Challenges page ("X challenged you"). Only the addressed member can accept. Members who already have the book accept without a guest seat.
- No match (or a number shared by several members): the sender gets "Text the link" with the number filled in. 20 lookups a day per member. Privacy Policy v3.
- Migration 0036. Also fixed: the custom date pickers showed even when "The full 12 weeks" was chosen.

## News and offers by email, opt-in (Nov 2026)

- Members opt in with "Email me news and offers" at sign-up (applied on first sync) or in My Account (`set_my_news_email`). Off by default.
- Admin Panel › Announcements: subject, plain-text message, optional button; "Send a test to me" then "Send to N members" (`admin_send_announcement`). Every email carries a one-click unsubscribe link (`unsubscribe.html?t=…` → `news_unsubscribe`) and the mailing address from Settings; sending is blocked until the address is set.
- Phone numbers are never used for marketing; no marketing texts. Privacy Policy v4. Migration 0037.

## Several seasons (Nov 2026)

- Admin Panel › Seasons: add any number of seasons (may overlap), edit, hide/show, and choose the **default**. Each row shows dates, status (Upcoming/Live week N/Finished), churches and people following it.
- Churches/groups pick their season in the Leader Console (Approvals card, "Season your members follow"); members follow the church's season. People without a church pick in My Account › Your season; otherwise they follow the default.
- `private.season_for(pid)` drives reading weeks, the book status, reminders, challenge default dates and the teen view. Seats/licenses stay one year from payment, so all 12 weeks stay open after a season ends.
- Migration 0038 (`seasons.listed`, `churches.season_id`, `partners.season_id`).

## Bookstore (Nov 2026)

- Admin Panel › Bookstore: add books (title, subtitle, author, price shown, description, cover upload or link, up to 3 buy buttons such as Amazon and IngramSpark Share & Sell), featured/order/show; clicks per button (30 days / all time).
- Members: `bookstore.html` (More › Bookstore, and a "Want a printed copy?" card on Get the Study Book). Buttons open the seller in a new tab; the seller takes the order, prints and ships.
- Migration 0039 (`store_books`, `store_clicks`, public `covers` bucket, admin-only uploads).

## Branded account emails (Nov 2026)

- `confirm.html` handles links from Supabase Auth emails on time4god.app: `?token_hash=…&type=email|recovery|magiclink|email_change` → `verifyOtp`; recovery shows "Set a new password".
- Templates to paste in Supabase › Authentication › Emails: `supabase/auth-email-templates/*.html` (they link to `{{ .SiteURL }}/confirm.html`, so no supabase.co link appears).
- Sender: set Custom SMTP in Supabase › Authentication › Emails › SMTP (Resend: smtp.resend.com, port 465, user `resend`, password = a Resend API key), sender notifications@time4god.app, name "Time4God Challenge". Site URL: https://time4god.app.
