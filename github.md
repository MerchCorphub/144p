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
| Older admin dashboard (partly sample data) | 144P-Admin.dc.html, admin-data.js, cloud.js |
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
- Every paid individual purchase (including "keep going") includes one guest seat (`guest_passes`, migration 0016).
- Sending a person challenge needs the study book. The first person who accepts gets the study book through the challenge's end date, using the sender's guest seat.
- Guests can't send person challenges. From the day they accept until 30 days after their challenge ends, they can buy their own year at the current individual price minus $5 (`keep_going` checkout).
- Admin Panel › Dashboard shows guest seats given, used, reading now, and kept going.
