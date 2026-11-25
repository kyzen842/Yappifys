# Yappify roadmap

- [x] Phase 1: layout and design with mock data
- [ ] Phase 2: auth (email + Google), tables, RLS, Yappify HQ
- [ ] Phase 3: realtime chat and DMs
- [ ] Phase 4: Friends, Find people, Inbox
- [ ] Phase 5: Yappi bot DMs
- [ ] Phase 6: Settings and Badges
- [ ] Phase 7: Admin panel

## Requests
- [x] Remove all fictional demo people (keep only the bot), rename bot "Yappi" → "Yappify"
- [x] Remove demo servers (keep only Yappify HQ)
- [x] Add sign up and login (email + Google) with profiles — start of Phase 2
- [x] Make zypherwastaken88@gmail.com a platform admin (role assigned server-side on signup); admin panel UI itself is Phase 7
- [x] Onboarding for new users: pick username, display name, avatar, banner, status before entering the app
- [x] Yappify HQ channels from screenshot: categories Start Here (welcome, rules, announcements, changelog), Community (general, introductions, media, memes, gaming, music, self-promo), Support (help, suggestions, bug-reports + keep feedback), Voice (Lounge, Gaming, Music); "About this server" button; #bug-reports gets a "Report a Bug" bar
- [x] Use the Yappify mascot logo as the Yappify HQ server icon
- [x] Admin entry: Admin button (only for admins) + starter /admin page now; full admin tools in Phase 7
- [ ] Calling: voice + video calls in DMs (phone/video buttons in DM header like screenshot) — Phase 3 (needs realtime)
- [ ] Richer profile card like screenshot: badges row, mutual friends/servers, member since / friends since
- [ ] Phase 7 admin panel (pulled forward at user request): dashboard, users (search/ban/mute/role), servers (HQ protected), reports queue, badges (create/grant/revoke), bot messages (one user / group / everyone), audit log
- [ ] Finish Phase 7 screens: wire dashboard/users into /admin, servers, reports queue, badges, bot messages, audit log
- [ ] Phase 3 (pulled forward): real servers/channels/messages/DMs in the database with realtime, reactions, edit/delete, image uploads, typing, invites + server roles, HQ seeded, calling in DMs
- [x] Yappify HQ owner = zypherwastaken88@gmail.com (not the bot); Yappify bot shown under an "Official Bot" role
- [ ] Everyone who signed up shows in Yappify HQ (real member list + shared HQ channel messages)
- [ ] When an update is published, Yappify bot posts in HQ #changelog: version number + what changed
- [x] Give zypherwastaken88@gmail.com every badge + new "Owner" badge

## Current request (Nov 23)
- [ ] Phase 3: real servers/channels/messages/DMs/groups for every server (not just HQ), unreads, typing, invites, leave
- [ ] Phase 4: real friends (requests/accept/block), Find people, Inbox (mentions + replies + friend requests)
- [ ] Phase 5: Yappify bot DMs (admin bot messages land in the bot DM)
- [ ] Phase 6: real badges (earned/equip in DB), settings save to DB
- [ ] Calling: voice + video in DMs/groups (ring, accept/decline, mute, camera, hang up) + voice channels
- [ ] Status picker like screenshot: Online, Idle, Do Not Disturb (no notifications), Invisible (appear offline)
- [ ] Admin panel entry: shield button in the left server rail under the home button
- [ ] Profile card: badges row, mutual servers, member since; for admins: Joined date, Active X ago, Moderate button, Cases count, "…" menu
- [ ] Badges granted from the admin panel actually appear for that user (profile, Settings → Badges)
- [ ] New badges created in the admin panel appear for everyone automatically (badge list loads from the database, live)
- [ ] Refreshing the page must not re-show old notifications (only brand-new ones pop up)

## Requests (Nov 24)
- [x] Redesign Admin Panel to match screenshot layout and add dedicated moderation, staff, and analytics sections
- [ ] Admin shield button moves under the Direct Messages (home) button in the left rail (away from the theme toggle)
- [ ] Upgrade admin panel: profile admin tools (Joined, Active, Moderate, Cases, … menu) + nicer dashboard
- [ ] Yappify Partners: admins partner/unpartner servers in the admin panel; partner servers show a "Partner Server" badge
- [ ] After that: calling (voice + video in DMs/groups, voice channels)
