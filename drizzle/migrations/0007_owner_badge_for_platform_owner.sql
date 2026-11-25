INSERT INTO public.badges (id, name, description, how_to_earn, icon, tone, goal) VALUES
  ('owner', 'Owner', 'Owner of Yappify.', 'Only the Yappify owner has this.', 'crown', 8, NULL)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.handle_new_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE is_owner boolean;
BEGIN
  IF NOT NEW.is_bot THEN
    SELECT public.is_platform_admin_email(u.email) INTO is_owner FROM auth.users u WHERE u.id = NEW.id;
    INSERT INTO public.server_members (server_id, user_id, role)
    VALUES ('00000000-0000-0000-0000-000000000001', NEW.id, CASE WHEN coalesce(is_owner, false) THEN 'owner' ELSE 'member' END)
    ON CONFLICT DO NOTHING;
    IF coalesce(is_owner, false) THEN
      UPDATE public.servers SET owner_id = NEW.id WHERE id = '00000000-0000-0000-0000-000000000001' AND owner_id IS NULL;
    END IF;
    INSERT INTO public.notifications (user_id, kind, title, body, href)
    VALUES (NEW.id, 'system', 'Welcome to Yappify HQ', 'You were added to the official Yappify server.', '/channels/hq/welcome');
    INSERT INTO public.user_badges (user_id, badge_id, equipped) VALUES (NEW.id, 'early-yapper', true) ON CONFLICT DO NOTHING;
    IF coalesce(is_owner, false) THEN
      INSERT INTO public.user_badges (user_id, badge_id, equipped)
      SELECT NEW.id, b.id, false FROM public.badges b WHERE b.id <> 'early-yapper'
      ON CONFLICT DO NOTHING;
      UPDATE public.user_badges SET equipped = true WHERE user_id = NEW.id AND badge_id = 'owner';
    END IF;
  END IF;
  RETURN NEW;
END; $$;