-- ================= Tables =================
CREATE TABLE public.servers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  icon_url text,
  tone int NOT NULL DEFAULT 3,
  owner_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  is_official boolean NOT NULL DEFAULT false,
  invite_code text NOT NULL UNIQUE DEFAULT substr(md5(random()::text || clock_timestamp()::text), 1, 8),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT servers_name_len CHECK (char_length(trim(name)) BETWEEN 1 AND 60),
  CONSTRAINT servers_tone CHECK (tone BETWEEN 1 AND 8)
);

CREATE TABLE public.server_members (
  server_id uuid NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member',
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (server_id, user_id),
  CONSTRAINT server_members_role CHECK (role IN ('owner','moderator','member'))
);
CREATE INDEX server_members_user_idx ON public.server_members (user_id);

CREATE TABLE public.channels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  server_id uuid NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  slug text NOT NULL,
  name text NOT NULL,
  kind text NOT NULL DEFAULT 'text',
  category text,
  topic text,
  icon text,
  admin_only boolean NOT NULL DEFAULT false,
  position int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (server_id, slug),
  CONSTRAINT channels_kind CHECK (kind IN ('text','voice')),
  CONSTRAINT channels_name_len CHECK (char_length(name) BETWEEN 1 AND 60)
);

CREATE TABLE public.dm_threads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  is_group boolean NOT NULL DEFAULT false,
  name text,
  created_by uuid,
  last_message_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.dm_participants (
  thread_id uuid NOT NULL REFERENCES public.dm_threads(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  muted boolean NOT NULL DEFAULT false,
  last_read_at timestamptz NOT NULL DEFAULT now(),
  joined_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (thread_id, user_id)
);
CREATE INDEX dm_participants_user_idx ON public.dm_participants (user_id);

-- author_id NULL means the message was sent by the Yappify bot.
CREATE TABLE public.messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id uuid REFERENCES public.channels(id) ON DELETE CASCADE,
  thread_id uuid REFERENCES public.dm_threads(id) ON DELETE CASCADE,
  author_id uuid DEFAULT auth.uid() REFERENCES public.profiles(id) ON DELETE SET NULL,
  content text NOT NULL DEFAULT '',
  image_url text,
  reply_to_id uuid REFERENCES public.messages(id) ON DELETE SET NULL,
  edited_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT messages_one_target CHECK ((channel_id IS NULL) <> (thread_id IS NULL)),
  CONSTRAINT messages_len CHECK (char_length(content) <= 4000),
  CONSTRAINT messages_not_empty CHECK (char_length(trim(content)) > 0 OR image_url IS NOT NULL)
);
CREATE INDEX messages_channel_idx ON public.messages (channel_id, created_at);
CREATE INDEX messages_thread_idx ON public.messages (thread_id, created_at);

CREATE TABLE public.message_reactions (
  message_id uuid NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES public.profiles(id) ON DELETE CASCADE,
  emoji text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id, emoji),
  CONSTRAINT reactions_emoji_len CHECK (char_length(emoji) BETWEEN 1 AND 16)
);

CREATE TABLE public.channel_reads (
  channel_id uuid NOT NULL REFERENCES public.channels(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_read_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel_id, user_id)
);

-- ================= Grants =================
GRANT SELECT, DELETE ON public.servers TO authenticated;
GRANT UPDATE (name, icon_url, tone) ON public.servers TO authenticated;
GRANT ALL ON public.servers TO service_role;
GRANT SELECT, DELETE ON public.server_members TO authenticated;
GRANT ALL ON public.server_members TO service_role;
GRANT SELECT, INSERT, DELETE ON public.channels TO authenticated;
GRANT UPDATE (name, topic, category, icon, admin_only, position) ON public.channels TO authenticated;
GRANT ALL ON public.channels TO service_role;
GRANT SELECT ON public.dm_threads TO authenticated;
GRANT UPDATE (name) ON public.dm_threads TO authenticated;
GRANT ALL ON public.dm_threads TO service_role;
GRANT SELECT, DELETE ON public.dm_participants TO authenticated;
GRANT UPDATE (muted, last_read_at) ON public.dm_participants TO authenticated;
GRANT ALL ON public.dm_participants TO service_role;
GRANT SELECT, INSERT, DELETE ON public.messages TO authenticated;
GRANT UPDATE (content, edited_at) ON public.messages TO authenticated;
GRANT ALL ON public.messages TO service_role;
GRANT SELECT, INSERT, DELETE ON public.message_reactions TO authenticated;
GRANT ALL ON public.message_reactions TO service_role;
GRANT SELECT ON public.channel_reads TO authenticated;
GRANT ALL ON public.channel_reads TO service_role;

ALTER TABLE public.servers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.server_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dm_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dm_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channel_reads ENABLE ROW LEVEL SECURITY;

-- ================= Helper functions =================
CREATE OR REPLACE FUNCTION public.is_server_member(_server uuid, _user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.server_members WHERE server_id = _server AND user_id = _user)
$$;

CREATE OR REPLACE FUNCTION public.server_role(_server uuid, _user uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT role FROM public.server_members WHERE server_id = _server AND user_id = _user
$$;

-- Admins manage anything; owners/moderators manage their own non-official servers.
CREATE OR REPLACE FUNCTION public.can_manage_server(_server uuid, _user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_role(_user, 'admin') OR (
    NOT coalesce((SELECT is_official FROM public.servers WHERE id = _server), false)
    AND coalesce(public.server_role(_server, _user) IN ('owner','moderator'), false)
  )
$$;

CREATE OR REPLACE FUNCTION public.is_thread_participant(_thread uuid, _user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.dm_participants WHERE thread_id = _thread AND user_id = _user)
$$;

CREATE OR REPLACE FUNCTION public.thread_has_bot(_thread uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.dm_participants dp JOIN public.profiles p ON p.id = dp.user_id
    WHERE dp.thread_id = _thread AND p.is_bot
  )
$$;

CREATE OR REPLACE FUNCTION public.channel_server(_channel uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT server_id FROM public.channels WHERE id = _channel
$$;

CREATE OR REPLACE FUNCTION public.is_restricted(_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_moderation
    WHERE user_id = _user AND (banned_until > now() OR muted_until > now())
  )
$$;

CREATE OR REPLACE FUNCTION public.can_read_message(_message uuid, _user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.messages m
    WHERE m.id = _message AND (
      (m.channel_id IS NOT NULL AND public.is_server_member(public.channel_server(m.channel_id), _user))
      OR (m.thread_id IS NOT NULL AND public.is_thread_participant(m.thread_id, _user))
    )
  )
$$;

CREATE OR REPLACE FUNCTION public.shares_server(_a uuid, _b uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.server_members x JOIN public.server_members y ON y.server_id = x.server_id
    WHERE x.user_id = _a AND y.user_id = _b
  )
$$;

-- ================= Policies =================
CREATE POLICY "Members and admins see servers" ON public.servers FOR SELECT TO authenticated
  USING (public.is_server_member(id, auth.uid()) OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Managers edit servers" ON public.servers FOR UPDATE TO authenticated
  USING (public.can_manage_server(id, auth.uid())) WITH CHECK (public.can_manage_server(id, auth.uid()));
CREATE POLICY "Owners delete their servers, admins delete any" ON public.servers FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin') OR (owner_id = auth.uid() AND NOT is_official));

CREATE POLICY "Members see fellow members" ON public.server_members FOR SELECT TO authenticated
  USING (public.is_server_member(server_id, auth.uid()) OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Leave or kick" ON public.server_members FOR DELETE TO authenticated
  USING (
    (user_id = auth.uid() AND role <> 'owner')
    OR (role <> 'owner' AND public.can_manage_server(server_id, auth.uid()))
  );

CREATE POLICY "Members see channels" ON public.channels FOR SELECT TO authenticated
  USING (public.is_server_member(server_id, auth.uid()) OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Managers add channels" ON public.channels FOR INSERT TO authenticated
  WITH CHECK (public.can_manage_server(server_id, auth.uid()));
CREATE POLICY "Managers edit channels" ON public.channels FOR UPDATE TO authenticated
  USING (public.can_manage_server(server_id, auth.uid())) WITH CHECK (public.can_manage_server(server_id, auth.uid()));
CREATE POLICY "Managers delete channels" ON public.channels FOR DELETE TO authenticated
  USING (public.can_manage_server(server_id, auth.uid()));

CREATE POLICY "Participants see threads" ON public.dm_threads FOR SELECT TO authenticated
  USING (public.is_thread_participant(id, auth.uid()));
CREATE POLICY "Participants rename groups" ON public.dm_threads FOR UPDATE TO authenticated
  USING (is_group AND public.is_thread_participant(id, auth.uid())) WITH CHECK (is_group AND public.is_thread_participant(id, auth.uid()));

CREATE POLICY "Participants see each other" ON public.dm_participants FOR SELECT TO authenticated
  USING (public.is_thread_participant(thread_id, auth.uid()));
CREATE POLICY "Update own DM settings" ON public.dm_participants FOR UPDATE TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "Leave group DMs" ON public.dm_participants FOR DELETE TO authenticated
  USING (user_id = auth.uid() AND EXISTS (SELECT 1 FROM public.dm_threads t WHERE t.id = thread_id AND t.is_group));

CREATE POLICY "Read messages where you belong" ON public.messages FOR SELECT TO authenticated
  USING (
    (channel_id IS NOT NULL AND public.is_server_member(public.channel_server(channel_id), auth.uid()))
    OR (thread_id IS NOT NULL AND public.is_thread_participant(thread_id, auth.uid()))
    OR public.has_role(auth.uid(), 'admin')
  );
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
      OR (thread_id IS NOT NULL AND public.is_thread_participant(thread_id, auth.uid()) AND NOT public.thread_has_bot(thread_id))
    )
  );
CREATE POLICY "Edit own messages" ON public.messages FOR UPDATE TO authenticated
  USING (author_id = auth.uid()) WITH CHECK (author_id = auth.uid() AND NOT public.is_restricted(auth.uid()));
CREATE POLICY "Delete own or moderate" ON public.messages FOR DELETE TO authenticated
  USING (
    author_id = auth.uid()
    OR public.has_role(auth.uid(), 'admin')
    OR (channel_id IS NOT NULL AND public.can_manage_server(public.channel_server(channel_id), auth.uid()))
  );

CREATE POLICY "See reactions where you can read" ON public.message_reactions FOR SELECT TO authenticated
  USING (public.can_read_message(message_id, auth.uid()));
CREATE POLICY "React where you can read" ON public.message_reactions FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND public.can_read_message(message_id, auth.uid()) AND NOT public.is_restricted(auth.uid()));
CREATE POLICY "Remove own reactions" ON public.message_reactions FOR DELETE TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "See own read markers" ON public.channel_reads FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- ================= Integrity triggers =================
-- Nobody leaves or gets removed from an official server (except when the account or server itself is deleted).
CREATE OR REPLACE FUNCTION public.protect_official_membership()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.servers s WHERE s.id = OLD.server_id AND s.is_official)
     AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = OLD.user_id) THEN
    RAISE EXCEPTION 'Nobody can leave or be removed from Yappify HQ';
  END IF;
  RETURN OLD;
END; $$;
CREATE TRIGGER server_members_protect_official BEFORE DELETE ON public.server_members
  FOR EACH ROW EXECUTE FUNCTION public.protect_official_membership();

-- Only platform admins can delete an official server.
CREATE OR REPLACE FUNCTION public.protect_official_server()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF OLD.is_official AND NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only a platform admin can delete Yappify HQ';
  END IF;
  RETURN OLD;
END; $$;
CREATE TRIGGER servers_protect_official BEFORE DELETE ON public.servers
  FOR EACH ROW EXECUTE FUNCTION public.protect_official_server();

-- Edits always stamp edited_at; message targets can't be changed.
CREATE OR REPLACE FUNCTION public.stamp_message_edit()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.content IS DISTINCT FROM OLD.content THEN NEW.edited_at := now(); END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER messages_stamp_edit BEFORE UPDATE ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.stamp_message_edit();

CREATE OR REPLACE FUNCTION public.bump_thread()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.thread_id IS NOT NULL THEN
    UPDATE public.dm_threads SET last_message_at = NEW.created_at WHERE id = NEW.thread_id;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER messages_bump_thread AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public.bump_thread();

-- ================= Actions =================
CREATE OR REPLACE FUNCTION public.create_server(_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  INSERT INTO public.servers (name, owner_id, tone) VALUES (trim(_name), auth.uid(), 1 + floor(random() * 8)::int) RETURNING id INTO sid;
  INSERT INTO public.server_members (server_id, user_id, role) VALUES (sid, auth.uid(), 'owner');
  INSERT INTO public.channels (server_id, slug, name, category, topic, icon, position) VALUES
    (sid, 'general', 'general', 'Text channels', 'Welcome to ' || trim(_name) || '!', 'hash', 0),
    (sid, 'voice', 'Voice', 'Voice', NULL, 'headphones', 1);
  UPDATE public.channels SET kind = 'voice' WHERE server_id = sid AND slug = 'voice';
  INSERT INTO public.user_badges (user_id, badge_id) VALUES (auth.uid(), 'server-founder') ON CONFLICT DO NOTHING;
  RETURN sid;
END; $$;

CREATE OR REPLACE FUNCTION public.join_server(_code text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT id INTO sid FROM public.servers WHERE invite_code = lower(trim(regexp_replace(_code, '^.*/', '')));
  IF sid IS NULL THEN RAISE EXCEPTION 'That invite link is invalid or expired'; END IF;
  INSERT INTO public.server_members (server_id, user_id) VALUES (sid, auth.uid()) ON CONFLICT DO NOTHING;
  RETURN sid;
END; $$;

CREATE OR REPLACE FUNCTION public.regenerate_server_invite(_server uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE code text;
BEGIN
  IF NOT public.can_manage_server(_server, auth.uid()) THEN RAISE EXCEPTION 'Only owners and moderators can do this'; END IF;
  code := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
  UPDATE public.servers SET invite_code = code WHERE id = _server;
  RETURN code;
END; $$;

CREATE OR REPLACE FUNCTION public.set_member_role(_server uuid, _user uuid, _role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF _role NOT IN ('moderator','member') THEN RAISE EXCEPTION 'Role must be moderator or member'; END IF;
  IF NOT (public.has_role(auth.uid(), 'admin') OR public.server_role(_server, auth.uid()) = 'owner') THEN
    RAISE EXCEPTION 'Only the server owner can change roles';
  END IF;
  UPDATE public.server_members SET role = _role WHERE server_id = _server AND user_id = _user AND role <> 'owner';
END; $$;

CREATE OR REPLACE FUNCTION public.mark_channel_read(_channel uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_server_member(public.channel_server(_channel), auth.uid()) THEN RETURN; END IF;
  INSERT INTO public.channel_reads (channel_id, user_id, last_read_at) VALUES (_channel, auth.uid(), now())
  ON CONFLICT (channel_id, user_id) DO UPDATE SET last_read_at = now();
END; $$;

CREATE OR REPLACE FUNCTION public.my_channel_unreads()
RETURNS TABLE (channel_id uuid, server_id uuid, unread int) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id, c.server_id, count(m.id)::int
  FROM public.server_members sm
  JOIN public.channels c ON c.server_id = sm.server_id AND c.kind = 'text'
  LEFT JOIN public.channel_reads r ON r.channel_id = c.id AND r.user_id = sm.user_id
  JOIN public.messages m ON m.channel_id = c.id
    AND m.created_at > coalesce(r.last_read_at, sm.joined_at)
    AND m.author_id IS DISTINCT FROM sm.user_id
  WHERE sm.user_id = auth.uid()
  GROUP BY c.id, c.server_id
$$;

CREATE OR REPLACE FUNCTION public.my_thread_unreads()
RETURNS TABLE (thread_id uuid, unread int) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT dp.thread_id, count(m.id)::int
  FROM public.dm_participants dp
  JOIN public.messages m ON m.thread_id = dp.thread_id AND m.created_at > dp.last_read_at AND m.author_id IS DISTINCT FROM dp.user_id
  WHERE dp.user_id = auth.uid()
  GROUP BY dp.thread_id
$$;

-- Opens (or reuses) a 1:1 DM with someone you share a server with.
CREATE OR REPLACE FUNCTION public.open_dm(_other uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE tid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF _other = auth.uid() THEN RAISE EXCEPTION 'You cannot DM yourself'; END IF;
  SELECT t.id INTO tid FROM public.dm_threads t
  WHERE NOT t.is_group
    AND EXISTS (SELECT 1 FROM public.dm_participants a WHERE a.thread_id = t.id AND a.user_id = auth.uid())
    AND EXISTS (SELECT 1 FROM public.dm_participants b WHERE b.thread_id = t.id AND b.user_id = _other)
  LIMIT 1;
  IF tid IS NOT NULL THEN RETURN tid; END IF;
  IF NOT public.shares_server(auth.uid(), _other) THEN RAISE EXCEPTION 'You can only message people you share a server with'; END IF;
  INSERT INTO public.dm_threads (is_group, created_by) VALUES (false, auth.uid()) RETURNING id INTO tid;
  INSERT INTO public.dm_participants (thread_id, user_id) VALUES (tid, auth.uid()), (tid, _other);
  RETURN tid;
END; $$;

CREATE OR REPLACE FUNCTION public.create_group_dm(_user_ids uuid[], _name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE tid uuid; u uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF coalesce(array_length(_user_ids, 1), 0) < 1 OR array_length(_user_ids, 1) > 9 THEN
    RAISE EXCEPTION 'Pick between 1 and 9 people';
  END IF;
  FOREACH u IN ARRAY _user_ids LOOP
    IF NOT public.shares_server(auth.uid(), u) THEN RAISE EXCEPTION 'You can only add people you share a server with'; END IF;
  END LOOP;
  INSERT INTO public.dm_threads (is_group, name, created_by) VALUES (true, nullif(trim(_name), ''), auth.uid()) RETURNING id INTO tid;
  INSERT INTO public.dm_participants (thread_id, user_id)
  SELECT tid, x FROM unnest(array_append(_user_ids, auth.uid())) AS x GROUP BY x;
  RETURN tid;
END; $$;

CREATE OR REPLACE FUNCTION public.admin_delete_server(_server uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE sname text;
BEGIN
  PERFORM public.require_admin();
  SELECT name INTO sname FROM public.servers WHERE id = _server;
  DELETE FROM public.servers WHERE id = _server;
  PERFORM public.write_audit('server.delete', 'server', _server::text, jsonb_build_object('name', sname));
END; $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.is_server_member(uuid, uuid)', 'public.server_role(uuid, uuid)', 'public.can_manage_server(uuid, uuid)',
    'public.is_thread_participant(uuid, uuid)', 'public.thread_has_bot(uuid)', 'public.channel_server(uuid)',
    'public.is_restricted(uuid)', 'public.can_read_message(uuid, uuid)', 'public.shares_server(uuid, uuid)',
    'public.create_server(text)', 'public.join_server(text)', 'public.regenerate_server_invite(uuid)',
    'public.set_member_role(uuid, uuid, text)', 'public.mark_channel_read(uuid)', 'public.my_channel_unreads()',
    'public.my_thread_unreads()', 'public.open_dm(uuid)', 'public.create_group_dm(uuid[], text)', 'public.admin_delete_server(uuid)'
  ] LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
  END LOOP;
END $$;
REVOKE EXECUTE ON FUNCTION public.protect_official_membership() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.protect_official_server() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bump_thread() FROM PUBLIC, anon, authenticated;

-- ================= Yappify HQ =================
INSERT INTO public.servers (id, name, tone, is_official, invite_code)
VALUES ('00000000-0000-0000-0000-000000000001', 'Yappify HQ', 1, true, 'yappifyhq')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.channels (server_id, slug, name, kind, category, topic, icon, admin_only, position) VALUES
  ('00000000-0000-0000-0000-000000000001', 'welcome', 'welcome', 'text', 'Start Here', 'Start here! What Yappify HQ is all about.', 'hand', true, 0),
  ('00000000-0000-0000-0000-000000000001', 'rules', 'rules', 'text', 'Start Here', 'Be kind. Keep it fun.', 'scroll', true, 1),
  ('00000000-0000-0000-0000-000000000001', 'announcements', 'announcements', 'text', 'Start Here', 'Official news from the Yappify team', 'megaphone', true, 2),
  ('00000000-0000-0000-0000-000000000001', 'changelog', 'changelog', 'text', 'Start Here', 'What''s new in Yappify', 'changelog', true, 3),
  ('00000000-0000-0000-0000-000000000001', 'general', 'general', 'text', 'Community', 'Say hi to everyone on Yappify!', 'chat', false, 10),
  ('00000000-0000-0000-0000-000000000001', 'introductions', 'introductions', 'text', 'Community', 'New here? Tell us about yourself.', 'sparkles', false, 11),
  ('00000000-0000-0000-0000-000000000001', 'media', 'media', 'text', 'Community', 'Pics, clips and creations', 'image', false, 12),
  ('00000000-0000-0000-0000-000000000001', 'memes', 'memes', 'text', 'Community', 'Only the finest memes', 'smile', false, 13),
  ('00000000-0000-0000-0000-000000000001', 'gaming', 'gaming', 'text', 'Community', 'What are you playing?', 'gamepad', false, 14),
  ('00000000-0000-0000-0000-000000000001', 'music', 'music', 'text', 'Community', 'Share your current obsession', 'music', false, 15),
  ('00000000-0000-0000-0000-000000000001', 'self-promo', 'self-promo', 'text', 'Community', 'Show off what you make', 'globe', false, 16),
  ('00000000-0000-0000-0000-000000000001', 'help', 'help', 'text', 'Support', 'Stuck? Ask here.', 'help', false, 20),
  ('00000000-0000-0000-0000-000000000001', 'suggestions', 'suggestions', 'text', 'Support', 'Ideas to make Yappify better', 'lightbulb', false, 21),
  ('00000000-0000-0000-0000-000000000001', 'feedback', 'feedback', 'text', 'Support', 'Tell us what you think', 'feedback', false, 22),
  ('00000000-0000-0000-0000-000000000001', 'bug-reports', 'bug-reports', 'text', 'Support', 'Found something broken? Tell us what happened and how.', 'bug', false, 23),
  ('00000000-0000-0000-0000-000000000001', 'lounge', 'Lounge', 'voice', 'Voice', NULL, 'headphones', false, 30),
  ('00000000-0000-0000-0000-000000000001', 'gaming-voice', 'Gaming', 'voice', 'Voice', NULL, 'gamepad', false, 31),
  ('00000000-0000-0000-0000-000000000001', 'music-voice', 'Music', 'voice', 'Voice', NULL, 'music', false, 32)
ON CONFLICT (server_id, slug) DO NOTHING;

INSERT INTO public.messages (channel_id, author_id, content, created_at)
SELECT c.id, NULL, v.content, now() - interval '1 hour'
FROM (VALUES
  ('welcome', '👋 Welcome to **Yappify HQ**! Read #rules, introduce yourself in #introductions, then come hang out in #general. Found a bug? Use #bug-reports.'),
  ('rules', '**1.** Be kind — no harassment or hate.' || chr(10) || '**2.** No spam or unsolicited self-promo (use #self-promo).' || chr(10) || '**3.** Keep it safe for everyone.' || chr(10) || '**4.** Report problems to the team instead of starting drama.' || chr(10) || '**5.** Have fun and keep yapping! 💜'),
  ('announcements', '📣 Welcome to Yappify HQ! This is the official home of Yappify. Announcements land here first.'),
  ('changelog', '**v0.2** — Live chat is here: servers, channels, DMs, reactions, replies, image uploads and typing indicators.')
) AS v(slug, content)
JOIN public.channels c ON c.server_id = '00000000-0000-0000-0000-000000000001' AND c.slug = v.slug;

-- Every new person joins HQ automatically (extends the signup welcome).
CREATE OR REPLACE FUNCTION public.handle_new_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT NEW.is_bot THEN
    INSERT INTO public.server_members (server_id, user_id, role)
    VALUES ('00000000-0000-0000-0000-000000000001', NEW.id, 'member') ON CONFLICT DO NOTHING;
    INSERT INTO public.notifications (user_id, kind, title, body, href)
    VALUES (NEW.id, 'system', 'Welcome to Yappify HQ', 'You were added to the official Yappify server.', '/channels/hq/welcome');
    INSERT INTO public.user_badges (user_id, badge_id, equipped) VALUES (NEW.id, 'early-yapper', true) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END; $$;

-- Backfill: everyone already signed up joins HQ
INSERT INTO public.server_members (server_id, user_id, role)
SELECT '00000000-0000-0000-0000-000000000001', id, 'member' FROM public.profiles WHERE NOT is_bot
ON CONFLICT DO NOTHING;

-- ================= Stats =================
CREATE OR REPLACE FUNCTION public.admin_stats()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.require_admin();
  RETURN jsonb_build_object(
    'users', (SELECT count(*) FROM public.profiles WHERE NOT is_bot),
    'servers', (SELECT count(*) FROM public.servers),
    'open_reports', (SELECT count(*) FROM public.reports WHERE status = 'open'),
    'banned', (SELECT count(*) FROM public.user_moderation WHERE banned_until > now()),
    'muted', (SELECT count(*) FROM public.user_moderation WHERE muted_until > now()),
    'signups_per_day', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('day', d::date, 'count', (
        SELECT count(*) FROM public.profiles p WHERE p.created_at::date = d::date AND NOT p.is_bot
      )) ORDER BY d), '[]'::jsonb)
      FROM generate_series(current_date - 13, current_date, interval '1 day') d
    ),
    'messages_per_day', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('day', d::date, 'count', (
        SELECT count(*) FROM public.messages m WHERE m.created_at::date = d::date
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

-- ================= Realtime =================
ALTER TABLE public.messages REPLICA IDENTITY FULL;
ALTER TABLE public.message_reactions REPLICA IDENTITY FULL;
ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
ALTER PUBLICATION supabase_realtime ADD TABLE public.message_reactions;
ALTER PUBLICATION supabase_realtime ADD TABLE public.server_members;
ALTER PUBLICATION supabase_realtime ADD TABLE public.channels;
ALTER PUBLICATION supabase_realtime ADD TABLE public.dm_participants;