-- Admins can read every role row
CREATE POLICY "Admins can view all roles"
  ON public.user_roles FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

-- ===== Audit log =====
CREATE TABLE public.audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid,
  action text NOT NULL,
  target_type text,
  target_id text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.audit_log TO authenticated;
GRANT ALL ON public.audit_log TO service_role;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read audit log" ON public.audit_log FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));
CREATE INDEX audit_log_created_idx ON public.audit_log (created_at DESC);

CREATE OR REPLACE FUNCTION public.write_audit(_action text, _target_type text, _target_id text, _details jsonb)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.audit_log (actor_id, action, target_type, target_id, details)
  VALUES (auth.uid(), _action, _target_type, _target_id, coalesce(_details, '{}'::jsonb));
$$;
REVOKE EXECUTE ON FUNCTION public.write_audit(text, text, text, jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.require_admin()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can do this' USING ERRCODE = '42501';
  END IF;
END; $$;
REVOKE EXECUTE ON FUNCTION public.require_admin() FROM PUBLIC, anon;

-- ===== Moderation =====
CREATE TABLE public.user_moderation (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  banned_until timestamptz,
  muted_until timestamptz,
  reason text,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.user_moderation TO authenticated;
GRANT ALL ON public.user_moderation TO service_role;
ALTER TABLE public.user_moderation ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users see own moderation, admins see all" ON public.user_moderation FOR SELECT TO authenticated
  USING (auth.uid() = user_id OR public.has_role(auth.uid(), 'admin'));

-- ===== Badges =====
CREATE TABLE public.badges (
  id text PRIMARY KEY,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  how_to_earn text NOT NULL DEFAULT '',
  icon text NOT NULL DEFAULT 'sparkles',
  tone int NOT NULL DEFAULT 1,
  goal int,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT badges_id_format CHECK (id ~ '^[a-z0-9-]{2,40}$'),
  CONSTRAINT badges_tone_range CHECK (tone BETWEEN 1 AND 8)
);
GRANT SELECT ON public.badges TO authenticated;
GRANT ALL ON public.badges TO service_role;
ALTER TABLE public.badges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Everyone signed in can view badges" ON public.badges FOR SELECT TO authenticated USING (true);

INSERT INTO public.badges (id, name, description, how_to_earn, icon, tone, goal) VALUES
  ('early-yapper', 'Early Yapper', 'Joined Yappify in the early days.', 'Sign up during the launch season.', 'sparkles', 1, NULL),
  ('yappify-staff', 'Yappify Staff', 'Part of the Yappify team.', 'Granted to Yappify team members.', 'shield', 7, NULL),
  ('bug-hunter', 'Bug Hunter', 'Reported a confirmed bug.', 'Report a bug in #bug-reports that gets confirmed.', 'bug', 3, 1),
  ('verified', 'Verified', 'Verified account.', 'Granted by Yappify admins.', 'badge-check', 2, NULL),
  ('7-day-streak', '7-Day Streak', 'Kept a chat streak for 7 days.', 'Send 3 messages a day for 7 days in a row.', 'flame', 5, 7),
  ('30-day-streak', '30-Day Streak', 'Kept a chat streak for 30 days.', 'Send 3 messages a day for 30 days in a row.', 'trophy', 4, 30),
  ('server-founder', 'Server Founder', 'Created a server.', 'Create your first server.', 'crown', 6, NULL)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE public.user_badges (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  badge_id text NOT NULL REFERENCES public.badges(id) ON DELETE CASCADE,
  equipped boolean NOT NULL DEFAULT false,
  granted_by uuid,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, badge_id)
);
GRANT SELECT ON public.user_badges TO authenticated;
GRANT UPDATE (equipped) ON public.user_badges TO authenticated;
GRANT ALL ON public.user_badges TO service_role;
ALTER TABLE public.user_badges ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Everyone signed in can view earned badges" ON public.user_badges FOR SELECT TO authenticated USING (true);
CREATE POLICY "Users equip their own badges" ON public.user_badges FOR UPDATE TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.enforce_equip_limit()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.equipped AND (SELECT count(*) FROM public.user_badges WHERE user_id = NEW.user_id AND equipped AND badge_id <> NEW.badge_id) >= 3 THEN
    RAISE EXCEPTION 'You can equip up to 3 badges';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER user_badges_equip_limit BEFORE INSERT OR UPDATE ON public.user_badges
  FOR EACH ROW EXECUTE FUNCTION public.enforce_equip_limit();

-- ===== Reports =====
CREATE TABLE public.reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id uuid NOT NULL DEFAULT auth.uid(),
  target_type text NOT NULL,
  target_id text NOT NULL,
  target_label text,
  reason text NOT NULL,
  details text,
  status text NOT NULL DEFAULT 'open',
  resolution_note text,
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reports_target_type CHECK (target_type IN ('user','message')),
  CONSTRAINT reports_status CHECK (status IN ('open','resolved','dismissed'))
);
GRANT SELECT, INSERT ON public.reports TO authenticated;
GRANT ALL ON public.reports TO service_role;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users file reports as themselves" ON public.reports FOR INSERT TO authenticated
  WITH CHECK (reporter_id = auth.uid() AND status = 'open' AND resolved_by IS NULL);
CREATE POLICY "Reporters see own reports, admins see all" ON public.reports FOR SELECT TO authenticated
  USING (reporter_id = auth.uid() OR public.has_role(auth.uid(), 'admin'));

-- ===== Notifications =====
CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'system',
  title text NOT NULL,
  body text NOT NULL DEFAULT '',
  href text,
  actor_id uuid,
  read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notifications_kind CHECK (kind IN ('mention','friend_request','bot','reply','system'))
);
GRANT SELECT ON public.notifications TO authenticated;
GRANT UPDATE (read) ON public.notifications TO authenticated;
GRANT ALL ON public.notifications TO service_role;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users see own notifications" ON public.notifications FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users mark own notifications read" ON public.notifications FOR UPDATE TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE INDEX notifications_user_idx ON public.notifications (user_id, created_at DESC);
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;

-- ===== Admin actions (all audited) =====
CREATE OR REPLACE FUNCTION public.admin_set_role(_user_id uuid, _role public.app_role, _grant boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.require_admin();
  IF _role = 'user' THEN RAISE EXCEPTION 'Everyone keeps the basic user role'; END IF;
  IF _grant THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (_user_id, _role) ON CONFLICT DO NOTHING;
  ELSE
    IF _role = 'admin' AND (SELECT count(*) FROM public.user_roles WHERE role = 'admin') <= 1 THEN
      RAISE EXCEPTION 'Yappify needs at least one admin';
    END IF;
    DELETE FROM public.user_roles WHERE user_id = _user_id AND role = _role;
  END IF;
  PERFORM public.write_audit(CASE WHEN _grant THEN 'role.grant' ELSE 'role.revoke' END, 'user', _user_id::text, jsonb_build_object('role', _role));
END; $$;

CREATE OR REPLACE FUNCTION public.admin_set_moderation(_user_id uuid, _banned_until timestamptz, _muted_until timestamptz, _reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.require_admin();
  IF _user_id = auth.uid() THEN RAISE EXCEPTION 'You cannot ban or mute yourself'; END IF;
  IF public.has_role(_user_id, 'admin') AND (_banned_until IS NOT NULL OR _muted_until IS NOT NULL) THEN
    RAISE EXCEPTION 'Remove their admin role before banning or muting an admin';
  END IF;
  INSERT INTO public.user_moderation (user_id, banned_until, muted_until, reason, updated_by, updated_at)
  VALUES (_user_id, _banned_until, _muted_until, nullif(_reason, ''), auth.uid(), now())
  ON CONFLICT (user_id) DO UPDATE SET banned_until = EXCLUDED.banned_until, muted_until = EXCLUDED.muted_until,
    reason = EXCLUDED.reason, updated_by = EXCLUDED.updated_by, updated_at = now();
  PERFORM public.write_audit('user.moderation', 'user', _user_id::text,
    jsonb_build_object('banned_until', _banned_until, 'muted_until', _muted_until, 'reason', _reason));
END; $$;

CREATE OR REPLACE FUNCTION public.admin_upsert_badge(_id text, _name text, _description text, _how_to_earn text, _icon text, _tone int)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.require_admin();
  INSERT INTO public.badges (id, name, description, how_to_earn, icon, tone)
  VALUES (_id, _name, coalesce(_description, ''), coalesce(_how_to_earn, ''), coalesce(_icon, 'sparkles'), coalesce(_tone, 1))
  ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description,
    how_to_earn = EXCLUDED.how_to_earn, icon = EXCLUDED.icon, tone = EXCLUDED.tone;
  PERFORM public.write_audit('badge.upsert', 'badge', _id, jsonb_build_object('name', _name));
END; $$;

CREATE OR REPLACE FUNCTION public.admin_set_user_badge(_user_id uuid, _badge_id text, _grant boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE badge_name text;
BEGIN
  PERFORM public.require_admin();
  SELECT name INTO badge_name FROM public.badges WHERE id = _badge_id;
  IF badge_name IS NULL THEN RAISE EXCEPTION 'Unknown badge'; END IF;
  IF _grant THEN
    INSERT INTO public.user_badges (user_id, badge_id, granted_by) VALUES (_user_id, _badge_id, auth.uid())
    ON CONFLICT DO NOTHING;
    INSERT INTO public.notifications (user_id, kind, title, body, href)
    VALUES (_user_id, 'system', 'New badge: ' || badge_name, 'You earned the ' || badge_name || ' badge! Equip it in Settings → Badges.', NULL);
  ELSE
    DELETE FROM public.user_badges WHERE user_id = _user_id AND badge_id = _badge_id;
  END IF;
  PERFORM public.write_audit(CASE WHEN _grant THEN 'badge.grant' ELSE 'badge.revoke' END, 'user', _user_id::text, jsonb_build_object('badge', _badge_id));
END; $$;

CREATE OR REPLACE FUNCTION public.admin_resolve_report(_report_id uuid, _status text, _note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.require_admin();
  IF _status NOT IN ('open','resolved','dismissed') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  UPDATE public.reports SET status = _status, resolution_note = nullif(_note, ''),
    resolved_by = CASE WHEN _status = 'open' THEN NULL ELSE auth.uid() END,
    resolved_at = CASE WHEN _status = 'open' THEN NULL ELSE now() END
  WHERE id = _report_id;
  PERFORM public.write_audit('report.' || _status, 'report', _report_id::text, jsonb_build_object('note', _note));
END; $$;

-- Sends a message from the Yappify bot to one user, a list of users, or everyone. Returns how many got it.
CREATE OR REPLACE FUNCTION public.admin_send_bot_message(_audience text, _user_ids uuid[], _title text, _body text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sent int;
BEGIN
  PERFORM public.require_admin();
  IF coalesce(trim(_body), '') = '' THEN RAISE EXCEPTION 'Message cannot be empty'; END IF;
  IF _audience = 'everyone' THEN
    INSERT INTO public.notifications (user_id, kind, title, body, href)
    SELECT p.id, 'bot', coalesce(nullif(_title, ''), 'Yappify'), _body, '/channels/me/yappify'
    FROM public.profiles p WHERE NOT p.is_bot;
  ELSIF _audience IN ('user', 'group') THEN
    INSERT INTO public.notifications (user_id, kind, title, body, href)
    SELECT p.id, 'bot', coalesce(nullif(_title, ''), 'Yappify'), _body, '/channels/me/yappify'
    FROM public.profiles p WHERE p.id = ANY(_user_ids) AND NOT p.is_bot;
  ELSE
    RAISE EXCEPTION 'Unknown audience';
  END IF;
  GET DIAGNOSTICS sent = ROW_COUNT;
  PERFORM public.write_audit('bot.message', 'audience', _audience,
    jsonb_build_object('title', _title, 'body', left(_body, 200), 'recipients', sent));
  RETURN sent;
END; $$;

CREATE OR REPLACE FUNCTION public.admin_stats()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.require_admin();
  RETURN jsonb_build_object(
    'users', (SELECT count(*) FROM public.profiles WHERE NOT is_bot),
    'open_reports', (SELECT count(*) FROM public.reports WHERE status = 'open'),
    'banned', (SELECT count(*) FROM public.user_moderation WHERE banned_until > now()),
    'muted', (SELECT count(*) FROM public.user_moderation WHERE muted_until > now()),
    'signups_per_day', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('day', d::date, 'count', (
        SELECT count(*) FROM public.profiles p WHERE p.created_at::date = d::date AND NOT p.is_bot
      )) ORDER BY d), '[]'::jsonb)
      FROM generate_series(current_date - 13, current_date, interval '1 day') d
    ),
    'bot_messages_per_day', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('day', d::date, 'count', (
        SELECT count(*) FROM public.notifications n WHERE n.created_at::date = d::date AND n.kind = 'bot'
      )) ORDER BY d), '[]'::jsonb)
      FROM generate_series(current_date - 13, current_date, interval '1 day') d
    )
  );
END; $$;

REVOKE EXECUTE ON FUNCTION public.admin_set_role(uuid, public.app_role, boolean) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_moderation(uuid, timestamptz, timestamptz, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_badge(text, text, text, text, text, int) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_set_user_badge(uuid, text, boolean) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_resolve_report(uuid, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_send_bot_message(text, uuid[], text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_role(uuid, public.app_role, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_moderation(uuid, timestamptz, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_upsert_badge(text, text, text, text, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_badge(uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_report(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_send_bot_message(text, uuid[], text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_stats() TO authenticated;

-- Welcome notification + Early Yapper badge on signup
CREATE OR REPLACE FUNCTION public.handle_new_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT NEW.is_bot THEN
    INSERT INTO public.notifications (user_id, kind, title, body, href)
    VALUES (NEW.id, 'system', 'Welcome to Yappify HQ', 'You were added to the official Yappify server.', '/channels/hq/welcome');
    INSERT INTO public.user_badges (user_id, badge_id, equipped) VALUES (NEW.id, 'early-yapper', true) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END; $$;
REVOKE EXECUTE ON FUNCTION public.handle_new_profile() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER on_profile_created AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_profile();

-- Backfill: existing users get Early Yapper
INSERT INTO public.user_badges (user_id, badge_id, equipped)
SELECT id, 'early-yapper', true FROM public.profiles WHERE NOT is_bot
ON CONFLICT DO NOTHING;