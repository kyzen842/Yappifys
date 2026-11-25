-- ===== Presence =====
ALTER TABLE public.profiles ADD COLUMN last_seen_at timestamptz NOT NULL DEFAULT now();
GRANT UPDATE (last_seen_at) ON public.profiles TO authenticated;
CREATE INDEX IF NOT EXISTS messages_author_idx ON public.messages (author_id, created_at);

-- ===== Friends =====
CREATE TABLE public.friendships (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  friend_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  state text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, friend_id),
  CONSTRAINT friendships_state CHECK (state IN ('pending','accepted','blocked')),
  CONSTRAINT friendships_not_self CHECK (user_id <> friend_id)
);
CREATE INDEX friendships_friend_idx ON public.friendships (friend_id);
GRANT SELECT ON public.friendships TO authenticated;
GRANT ALL ON public.friendships TO service_role;
ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;
CREATE POLICY "See your own relationships" ON public.friendships FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR (friend_id = auth.uid() AND state <> 'blocked'));

CREATE OR REPLACE FUNCTION public.is_blocked(_a uuid, _b uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.friendships
    WHERE state = 'blocked' AND ((user_id = _a AND friend_id = _b) OR (user_id = _b AND friend_id = _a))
  )
$$;

CREATE OR REPLACE FUNCTION public.send_friend_request(_user uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := auth.uid(); existing record; my_name text;
BEGIN
  IF me IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF _user = me THEN RAISE EXCEPTION 'You can''t add yourself'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = _user AND NOT is_bot) THEN
    RAISE EXCEPTION 'Hmm, that didn''t work. Double-check the username.';
  END IF;
  IF public.is_blocked(me, _user) THEN RAISE EXCEPTION 'You can''t send a friend request to this person'; END IF;
  SELECT * INTO existing FROM public.friendships
    WHERE (user_id = me AND friend_id = _user) OR (user_id = _user AND friend_id = me) LIMIT 1;
  SELECT display_name INTO my_name FROM public.profiles WHERE id = me;
  IF existing IS NOT NULL THEN
    IF existing.state = 'accepted' THEN RETURN 'already_friends'; END IF;
    IF existing.user_id = me THEN RETURN 'already_sent'; END IF;
    -- They already asked me: accept.
    UPDATE public.friendships SET state = 'accepted', updated_at = now() WHERE user_id = _user AND friend_id = me;
    INSERT INTO public.notifications (user_id, kind, title, body, href, actor_id)
    VALUES (_user, 'system', my_name || ' accepted your friend request', 'You''re now friends. Say hi!', '/channels/me', me);
    RETURN 'accepted';
  END IF;
  INSERT INTO public.friendships (user_id, friend_id, state) VALUES (me, _user, 'pending');
  INSERT INTO public.notifications (user_id, kind, title, body, href, actor_id)
  VALUES (_user, 'friend_request', my_name || ' sent you a friend request', 'Open Friends → Pending to accept it.', '/channels/me', me);
  RETURN 'sent';
END; $$;

CREATE OR REPLACE FUNCTION public.send_friend_request_by_username(_username text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE target uuid;
BEGIN
  SELECT id INTO target FROM public.profiles WHERE username = lower(trim(both '@' from trim(_username))) AND NOT is_bot;
  IF target IS NULL THEN RAISE EXCEPTION 'Hmm, that didn''t work. Double-check the username.'; END IF;
  RETURN public.send_friend_request(target);
END; $$;

CREATE OR REPLACE FUNCTION public.respond_friend_request(_user uuid, _accept boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := auth.uid(); my_name text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.friendships WHERE user_id = _user AND friend_id = me AND state = 'pending') THEN
    RAISE EXCEPTION 'That friend request is gone';
  END IF;
  IF _accept THEN
    UPDATE public.friendships SET state = 'accepted', updated_at = now() WHERE user_id = _user AND friend_id = me;
    SELECT display_name INTO my_name FROM public.profiles WHERE id = me;
    INSERT INTO public.notifications (user_id, kind, title, body, href, actor_id)
    VALUES (_user, 'system', my_name || ' accepted your friend request', 'You''re now friends. Say hi!', '/channels/me', me);
  ELSE
    DELETE FROM public.friendships WHERE user_id = _user AND friend_id = me;
  END IF;
END; $$;

-- Cancels a request you sent, or removes a friend.
CREATE OR REPLACE FUNCTION public.remove_friend(_user uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := auth.uid();
BEGIN
  DELETE FROM public.friendships
  WHERE state <> 'blocked' AND ((user_id = me AND friend_id = _user) OR (user_id = _user AND friend_id = me));
END; $$;

CREATE OR REPLACE FUNCTION public.block_user(_user uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := auth.uid();
BEGIN
  IF me IS NULL OR _user = me THEN RAISE EXCEPTION 'You can''t block yourself'; END IF;
  DELETE FROM public.friendships WHERE (user_id = me AND friend_id = _user) OR (user_id = _user AND friend_id = me AND state <> 'blocked');
  INSERT INTO public.friendships (user_id, friend_id, state) VALUES (me, _user, 'blocked');
END; $$;

CREATE OR REPLACE FUNCTION public.unblock_user(_user uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM public.friendships WHERE user_id = auth.uid() AND friend_id = _user AND state = 'blocked';
END; $$;

-- DMs respect blocks.
CREATE OR REPLACE FUNCTION public.open_dm(_other uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE tid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF _other = auth.uid() THEN RAISE EXCEPTION 'You cannot DM yourself'; END IF;
  IF public.is_blocked(auth.uid(), _other) THEN RAISE EXCEPTION 'You can''t message this person'; END IF;
  SELECT t.id INTO tid FROM public.dm_threads t
  WHERE NOT t.is_group
    AND EXISTS (SELECT 1 FROM public.dm_participants a WHERE a.thread_id = t.id AND a.user_id = auth.uid())
    AND EXISTS (SELECT 1 FROM public.dm_participants b WHERE b.thread_id = t.id AND b.user_id = _other)
  LIMIT 1;
  IF tid IS NOT NULL THEN RETURN tid; END IF;
  IF NOT (public.shares_server(auth.uid(), _other) OR EXISTS (
    SELECT 1 FROM public.friendships f WHERE f.state = 'accepted'
      AND ((f.user_id = auth.uid() AND f.friend_id = _other) OR (f.user_id = _other AND f.friend_id = auth.uid()))
  )) THEN RAISE EXCEPTION 'You can only message friends or people you share a server with'; END IF;
  INSERT INTO public.dm_threads (is_group, created_by) VALUES (false, auth.uid()) RETURNING id INTO tid;
  INSERT INTO public.dm_participants (thread_id, user_id) VALUES (tid, auth.uid()), (tid, _other);
  RETURN tid;
END; $$;

CREATE OR REPLACE FUNCTION public.thread_blocked_for(_thread uuid, _user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.dm_threads t JOIN public.dm_participants o ON o.thread_id = t.id AND o.user_id <> _user
    WHERE t.id = _thread AND NOT t.is_group AND public.is_blocked(_user, o.user_id)
  )
$$;

DROP POLICY "Post where you belong" ON public.messages;
CREATE POLICY "Post where you belong" ON public.messages FOR INSERT TO authenticated
  WITH CHECK (
    author_id = auth.uid()
    AND NOT public.is_restricted(auth.uid())
    AND (
      (channel_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.channels c
        WHERE c.id = channel_id AND c.kind = 'text'
          AND public.is_server_member(c.server_id, auth.uid())
          AND (NOT c.admin_only OR public.has_role(auth.uid(), 'admin'))
      ))
      OR (thread_id IS NOT NULL AND public.is_thread_participant(thread_id, auth.uid())
          AND NOT public.thread_has_bot(thread_id) AND NOT public.thread_blocked_for(thread_id, auth.uid()))
    )
  );

-- ===== Streaks =====
CREATE OR REPLACE FUNCTION public.streak_for(_user uuid)
RETURNS TABLE (current_streak int, best_streak int, today_count int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH days AS (
    SELECT (created_at AT TIME ZONE 'utc')::date AS d FROM public.messages
    WHERE author_id = _user GROUP BY 1 HAVING count(*) >= 3
  ), grp AS (
    SELECT d, d - (row_number() OVER (ORDER BY d))::int AS g FROM days
  ), runs AS (
    SELECT max(d) AS e, count(*)::int AS n FROM grp GROUP BY g
  )
  SELECT
    coalesce((SELECT n FROM runs WHERE e >= (now() AT TIME ZONE 'utc')::date - 1 ORDER BY e DESC LIMIT 1), 0),
    coalesce((SELECT max(n) FROM runs), 0),
    (SELECT count(*)::int FROM public.messages WHERE author_id = _user AND created_at >= date_trunc('day', now() AT TIME ZONE 'utc') AT TIME ZONE 'utc')
$$;

CREATE OR REPLACE FUNCTION public.my_streak()
RETURNS TABLE (current_streak int, best_streak int, today_count int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.streak_for(auth.uid())
$$;

-- ===== Mentions, replies, streak badges =====
CREATE OR REPLACE FUNCTION public.handle_new_message()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  author_name text; href text; parent_author uuid; s record; preview text;
BEGIN
  IF NEW.author_id IS NULL THEN RETURN NEW; END IF;
  SELECT display_name INTO author_name FROM public.profiles WHERE id = NEW.author_id;
  preview := left(coalesce(nullif(NEW.content, ''), '📷 Image'), 140);
  IF NEW.channel_id IS NOT NULL THEN
    SELECT '/channels/' || CASE WHEN c.server_id = '00000000-0000-0000-0000-000000000001' THEN 'hq' ELSE c.server_id::text END || '/' || c.slug
      INTO href FROM public.channels c WHERE c.id = NEW.channel_id;
  ELSE
    href := '/channels/me/' || NEW.thread_id::text;
  END IF;

  IF NEW.reply_to_id IS NOT NULL THEN
    SELECT author_id INTO parent_author FROM public.messages WHERE id = NEW.reply_to_id;
    IF parent_author IS NOT NULL AND parent_author <> NEW.author_id AND NOT public.is_blocked(parent_author, NEW.author_id) THEN
      INSERT INTO public.notifications (user_id, kind, title, body, href, actor_id)
      VALUES (parent_author, 'reply', author_name || ' replied to you', preview, href, NEW.author_id);
    END IF;
  END IF;

  INSERT INTO public.notifications (user_id, kind, title, body, href, actor_id)
  SELECT p.id, 'mention', author_name || ' mentioned you', preview, href, NEW.author_id
  FROM public.profiles p
  WHERE p.username IN (SELECT lower(m[1]) FROM regexp_matches(NEW.content, '@([A-Za-z0-9_.]{2,32})', 'g') AS m)
    AND p.id <> NEW.author_id
    AND p.id IS DISTINCT FROM parent_author
    AND NOT p.is_bot
    AND NOT public.is_blocked(p.id, NEW.author_id)
    AND (
      (NEW.channel_id IS NOT NULL AND public.is_server_member(public.channel_server(NEW.channel_id), p.id))
      OR (NEW.thread_id IS NOT NULL AND public.is_thread_participant(NEW.thread_id, p.id))
    );

  SELECT * INTO s FROM public.streak_for(NEW.author_id);
  IF s.current_streak >= 7 THEN
    INSERT INTO public.user_badges (user_id, badge_id) VALUES (NEW.author_id, '7-day-streak') ON CONFLICT DO NOTHING;
  END IF;
  IF s.current_streak >= 30 THEN
    INSERT INTO public.user_badges (user_id, badge_id) VALUES (NEW.author_id, '30-day-streak') ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER messages_notify AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_message();

-- ===== Calls =====
CREATE OR REPLACE FUNCTION public.can_access_room(_room text, _user uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE rid uuid;
BEGIN
  IF _room !~ '^(dm|vc):[0-9a-f-]{36}$' THEN RETURN false; END IF;
  rid := substr(_room, 4)::uuid;
  IF left(_room, 3) = 'dm:' THEN
    RETURN public.is_thread_participant(rid, _user) AND NOT public.thread_has_bot(rid) AND NOT public.thread_blocked_for(rid, _user);
  END IF;
  RETURN EXISTS (SELECT 1 FROM public.channels c WHERE c.id = rid AND c.kind = 'voice' AND public.is_server_member(c.server_id, _user));
END; $$;

CREATE TABLE public.call_participants (
  room text NOT NULL,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  muted boolean NOT NULL DEFAULT false,
  video boolean NOT NULL DEFAULT false,
  joined_at timestamptz NOT NULL DEFAULT now(),
  last_ping timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (room, user_id)
);
GRANT SELECT, INSERT, DELETE ON public.call_participants TO authenticated;
GRANT UPDATE (muted, video, last_ping) ON public.call_participants TO authenticated;
GRANT ALL ON public.call_participants TO service_role;
ALTER TABLE public.call_participants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "See calls you can join" ON public.call_participants FOR SELECT TO authenticated
  USING (public.can_access_room(room, auth.uid()));
CREATE POLICY "Join calls you can access" ON public.call_participants FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND public.can_access_room(room, auth.uid()) AND NOT public.is_restricted(auth.uid()));
CREATE POLICY "Update own call state" ON public.call_participants FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "Leave calls" ON public.call_participants FOR DELETE TO authenticated
  USING (user_id = auth.uid());

CREATE TABLE public.call_signals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room text NOT NULL,
  from_user uuid NOT NULL DEFAULT auth.uid(),
  to_user uuid NOT NULL,
  kind text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT call_signals_kind CHECK (kind IN ('ring','cancel','decline','offer','answer','ice','hangup'))
);
CREATE INDEX call_signals_to_idx ON public.call_signals (to_user, created_at);
GRANT SELECT, INSERT, DELETE ON public.call_signals TO authenticated;
GRANT ALL ON public.call_signals TO service_role;
ALTER TABLE public.call_signals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Send signals in your calls" ON public.call_signals FOR INSERT TO authenticated
  WITH CHECK (from_user = auth.uid() AND to_user <> auth.uid()
    AND public.can_access_room(room, auth.uid()) AND public.can_access_room(room, to_user));
CREATE POLICY "Read your signals" ON public.call_signals FOR SELECT TO authenticated
  USING (to_user = auth.uid() OR from_user = auth.uid());
CREATE POLICY "Clean up your signals" ON public.call_signals FOR DELETE TO authenticated
  USING (to_user = auth.uid() OR from_user = auth.uid());

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.is_blocked(uuid, uuid)', 'public.send_friend_request(uuid)', 'public.send_friend_request_by_username(text)',
    'public.respond_friend_request(uuid, boolean)', 'public.remove_friend(uuid)', 'public.block_user(uuid)', 'public.unblock_user(uuid)',
    'public.thread_blocked_for(uuid, uuid)', 'public.my_streak()', 'public.can_access_room(text, uuid)'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
END $$;
REVOKE EXECUTE ON FUNCTION public.streak_for(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_new_message() FROM PUBLIC, anon, authenticated;

-- ===== Realtime =====
ALTER TABLE public.call_signals REPLICA IDENTITY FULL;
ALTER TABLE public.call_participants REPLICA IDENTITY FULL;
ALTER TABLE public.friendships REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.friendships;
ALTER PUBLICATION supabase_realtime ADD TABLE public.call_participants;
ALTER PUBLICATION supabase_realtime ADD TABLE public.call_signals;
ALTER PUBLICATION supabase_realtime ADD TABLE public.badges;
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_badges;
ALTER PUBLICATION supabase_realtime ADD TABLE public.dm_threads;