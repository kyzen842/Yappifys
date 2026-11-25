<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.

## What Lovable manages

Rules outside this block are the project's own. Change the pieces below in
Lovable, not by hand. With the [Lovable MCP](https://mcp.lovable.dev)
connected, `send_message` asks Lovable to do it; otherwise ask the user to
use the editor.

- **Database.** Do not add or edit `supabase/migrations/` or `drizzle/`.
  Ask Lovable to change the schema.
- **Generated files.** Do not edit a file whose header says it is automatically
  generated.
- **AI gateway.** Keep model calls on Lovable's gateway, and keep
  `LOVABLE_API_KEY` out of browser code.
- **Connectors.** Lovable provides native connectors. `list_connectors` shows
  which are enabled; `add_connector` only returns the dashboard link. When a
  connector is enabled, calls go through the connector gateway and need
  `LOVABLE_API_KEY`. When Lovable does not provide one, users can bring their
  own key and store it in Secrets.
- **Secrets.** Lovable manages them. Do not put secret values in the repo.
<!-- LOVABLE:END -->

## Project rules

- Signed-in app routes live in `src/routes/_authenticated/` (`/channels/me`, `/channels/me/$threadId`, `/channels/$serverId/$channelId`, `/onboarding`, `/admin`); the shell (rail, sidebar, user panel, global dialogs) renders once in `_authenticated/channels.tsx`, whose beforeLoad sends un-onboarded users to `/onboarding`. Why: one shell stays mounted across navigation, and every app page requires sign-in + a finished profile.
- The signed-in account (profile + admin flag) comes from `myAccountQuery` in `src/lib/profile.ts`; the demo store's `me` is synced from it until chat data moves to the database. Why: one source of truth for who is signed in.
- Roles live only in `public.user_roles` and are assigned by database triggers (platform admin emails are listed in `public.is_platform_admin_email`). Frontend role checks are UI-only gates. Why: users must never grant themselves privileges.
- Profile images go to the private `profile-media` bucket under `<userId>/…` and are stored as long-lived signed URLs (workspace blocks public buckets). Why: private bucket policy.
- Global dialogs (inbox, settings, find people, create group, add server) open via the store's `openDialog`, not per-page state. Why: any panel/button can open them without prop drilling.
- Phase 1 data comes from `src/lib/mock-store.tsx` + `src/lib/mock-data.ts`; later phases replace these with Lovable Cloud queries behind the same component props. Why: UI was built first with fictional demo data.
- Pure business rules (badge count cap, find-people filtering) live in `src/lib/*.ts` with tests in `src/test/rules.test.ts`. Why: rules stay testable without rendering.
- Colors, gradients, and mascot fills are semantic tokens in `src/styles.css`; components never use raw color classes. Why: light/dark themes switch by token.
- Admin sections share the /admin search-based navigation; staff and moderation reuse the user management dialog, and analytics reuse existing statistics. Why: dedicated views do not duplicate privileged actions or data sources.
