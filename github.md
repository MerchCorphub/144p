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
| Partner app (all screens) | 144P-Plan-v2.dc.html, cloud.js |
| Book reader + join church | read.html, cloud.js |
| Time4God Challenge (send by text/email, accept, scoreboards) | challenges.html, cloud.js |
| Admin Panel (platform admin) | admin.html → leader.html?panel=admin |
| Leader Console (church admins, group leaders: approvals, groups) | leader.html, book-import.js, cloud.js |
| Older admin dashboard (partly sample data) | 144P-Admin.dc.html, admin-data.js, cloud.js |
| PWA | manifest.json, sw.js, icon-192.png, icon-512.png, apple-touch-icon.png |
| Database | supabase/migrations/0001_init.sql, 0002_harden_and_rpcs.sql, 0003_book_licenses_approvals.sql, 0004_church_admins.sql, 0005_book_hidden_sections.sql, 0006_challenges.sql, 0006b_challenges_null_safety.sql, 0007_groups.sql, 0008_payments.sql, 0009_email_notifications.sql |

## Payments (Stripe)
- Server function `supabase/functions/stripe-pay` (deployed on the 144p Supabase project). Needs the secret `STRIPE_SECRET_KEY` (Supabase › Edge Functions › Secrets). Use an `sk_test_` key for testing, then the `sk_live_` key to go live.
- Buyers pay on Stripe Checkout and come back to the page they left; the page confirms the payment with Stripe and turns the seat or license on. Prices come from Admin Panel › Prices. One-time payments that last one year; church upgrades pay the difference and keep the end date. Prices include tax; all sales final.

## Email notifications (Resend)
- Database triggers queue emails in `email_outbox`; a one-minute cron job wakes `supabase/functions/send-emails`, which sends through Resend. Needs the secret `RESEND_API_KEY`; optional `EMAIL_FROM` (default `Time4God Challenge <notifications@time4god.app>`) and `EMAIL_REPLY_TO`.
- Church admins and group leaders: each new join request for their church. Platform admins: new accounts, join requests, payments, new churches. Everyone can turn these off in the Leader Console (Approvals › "Email me about new members").
