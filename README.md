# Yappify

Build "Yappify", a Discord-style chat app using React, Tailwind, shadcn/ui, and
Supabase (auth, Postgres, Realtime, Storage, Edge Functions).

IMPORTANT: Build in the phases listed at the bottom. Finish each phase fully
before the next, and keep the app working at every step.

=== BRANDING & DESIGN ===
Use the attached screenshots ONLY as layout inspiration. Do not copy their
logo, mascot, name, usernames, or avatars. Create an original Yappify logo and
mascot (a friendly speech-bubble character). Light theme by default with a
violet accent, plus a dark mode toggle. Responsive, with collapsible columns on
mobile. In all mock/demo data use ONLY fictional placeholder people (e.g.
"Pixel Pete", "Nova", "Marsh"). Never seed fake people into the real users or
profiles tables.

=== LAYOUT ===
- Far-left server rail: Home (Yappify logo) at top, a divider, server icons with
  red unread-count badges, and a "+" button to add a server.
- Second column (Home view): "Direct messages" header, nav items Friends, Find
  people, Create group, then a "DIRECT MESSAGES" list with a "+" button. DM rows
  show avatar, name, status dot, and an optional profile banner background.
- Bottom-left user panel: avatar with status dot, username, short status text,
  an Inbox button with a red unread badge (99+ when large), a settings gear, and
  a log out button.
- Main area changes by route.

=== DATABASE ===
Auth: email + Google. Tables: profiles (username, avatar_url, banner_url, status,
is_bot), servers, server_members, channels, messages, friendships, dm_threads,
notifications, badges, user_badges, user_roles, reports, audit_log.
RLS: users only see servers they belong to. Roles live in a separate user_roles
table and are checked with a security definer function, never on the frontend
alone or on profiles.

=== YAPPIFY HQ (mandatory server) ===
Create a system server "Yappify HQ" with channels #announcements (only admins
can post), #general, #feedback, #bug-reports.
- A trigger auto-adds every new user on signup, and backfills existing users.
- Enforced with triggers and RLS: normal users cannot leave, be kicked from, or
  be banned from Yappify HQ. Hide "Leave server" and show an "Official" tag.
- Only a platform admin can delete it.

=== BOT DMs (read-only) ===
Add a system bot "Yappi" (is_bot = true, shown with a BOT tag). Every new user
automatically gets a DM thread with Yappi and a welcome message.
- Users can READ bot messages but cannot SEND to a bot DM. Replace the composer
  with a disabled bar: "You can't reply to this bot."
- Enforce in RLS: the messages insert policy rejects any message in a thread with
  a bot participant unless the sender is the bot.
- Bot messages are sent only via a Supabase Edge Function using the service role
  key, and each one creates a notification.
- Bot DMs can't be deleted by users, only muted.

=== FRIENDS PAGE ===
Tabs: Online, All, Pending, Blocked, Suggested, plus a highlighted "Add Friend"
button. Top card "Invite a friend" shows a personal link (yappify.app/add/<code>)
with Copy and "New link" (regenerates the code). Below: a search box and an
"ONLINE - N" list. Empty state: sleeping mascot, "Nobody's online right now.
Your friends are taking a break.", and an Add Friend button.
Backend: send/accept/decline requests, block/unblock, realtime presence. Opening
an invite link creates a friend request or instant friendship.
"Find people" modal: "Search your friends and anyone online in your servers."
Search by name, require 2+ letters (hint: "Type at least 2 letters."), and only
return people who share a server with the user or are already friends.

=== SETTINGS ===
Modal (full-screen on mobile) with a "Search settings" box and left nav:
USER SETTINGS: My Account, My Profile, Badges
APP SETTINGS: Appearance, Chat, Language, Voice & Audio, Sounds, Notifications,
Keybinds, Advanced
My Account: chat streak (current, best, "send 3 messages a day", streak freeze),
toggle "Show my streak on my profile", "Download your data" (JSON export), Log
out, Log out of all devices, and a red Delete account section.

BADGES: Grid of all badges. Earned ones in full color, locked ones greyed with a
"how to earn" tooltip and a progress bar where relevant. Users can equip up to 3,
shown on their profile card and next to their username in chat.
Seed badges: Early Yapper, Yappify Staff, Bug Hunter, Verified, 7-Day Streak,
30-Day Streak, Server Founder.
Awarding is server-side only (function or trigger). Users cannot insert their own
user_badges rows.

=== INBOX ===
Modal opened from the user panel's inbox button. Tabs: For you, Mentions,
Unreads, with count pills and "Mark all read". Empty state: mascot with a check
mark, "You're all caught up", and a "Find friends" button. Backed by the
notifications table with realtime updates.

=== CHAT ===
Realtime messages via Supabase Realtime: replies, emoji reactions, edit/delete
own messages, image uploads (Storage), typing indicators. Servers with invite
links and roles (owner, moderator, member), plus 1:1 and group DMs.

=== ADMIN PANEL (/admin, platform admins only) ===
- Dashboard: users, servers, messages per day.
- Users: search, ban, mute, change role.
- Servers: moderation tools (Yappify HQ protected from deletion).
- Reports queue for reported messages and users.
- Badges: create badges, grant or revoke for users.
- Bot messages: compose and send as Yappi to one user, a group, or everyone via
  the edge function.
- Audit log of every admin action.

=== BUILD ORDER ===
Phase 1: layout and design with mock data.
Phase 2: Supabase auth, tables, RLS, Yappify HQ.
Phase 3: realtime chat and DMs.
Phase 4: Friends, Find people, Inbox.
Phase 5: Yappi bot DMs.
Phase 6: Settings and Badges.
Phase 7: Admin panel.
Pause after each phase and tell me what to test.

This project was built with [Lovable](https://lovable.dev).

**Live app**: https://yappify.lovable.app

## Build with Lovable

Continue developing this project in the [Lovable editor](https://lovable.dev/projects/fe83438e-ea1d-442a-bd43-42487b2d3ca3).

- **Ship faster**: describe what you want to build and Lovable handles the code.
- **Stay in sync**: every change made in Lovable is committed straight to this repository.
- **Full ownership**: this code is yours. Push to `main` on GitHub and your changes sync back into Lovable, ready for your next prompt.

## Development

Prefer working locally? You need Node.js and npm — [install with nvm](https://github.com/nvm-sh/nvm#installing-and-updating).

```sh
git clone <this-repository-url>
cd <repository-name>
npm i
npm run dev
```
