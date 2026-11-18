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
| Database | supabase/migrations/0001_init.sql, 0002_harden_and_rpcs.sql, 0003_book_licenses_approvals.sql, 0004_church_admins.sql, 0005_book_hidden_sections.sql, 0006_challenges.sql, 0006b_challenges_null_safety.sql, 0007_groups.sql |
