ALTER TABLE public.servers ADD COLUMN IF NOT EXISTS is_partner boolean NOT NULL DEFAULT false;
ALTER TABLE public.servers ADD COLUMN IF NOT EXISTS partnered_at timestamptz;

-- Only platform admins may change a server's official or partner status (server managers can still rename etc.).
CREATE OR REPLACE FUNCTION public.protect_server_flags()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF (NEW.is_partner IS DISTINCT FROM OLD.is_partner
      OR NEW.partnered_at IS DISTINCT FROM OLD.partnered_at
      OR NEW.is_official IS DISTINCT FROM OLD.is_official)
     AND NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only a platform admin can change partner or official status';
  END IF;
  RETURN NEW;
END; $$;
REVOKE EXECUTE ON FUNCTION public.protect_server_flags() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS servers_protect_flags ON public.servers;
CREATE TRIGGER servers_protect_flags BEFORE UPDATE ON public.servers
  FOR EACH ROW EXECUTE FUNCTION public.protect_server_flags();

CREATE OR REPLACE FUNCTION public.admin_set_server_partner(_server uuid, _partner boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE _name text; _official boolean;
BEGIN
  PERFORM public.require_admin();
  SELECT name, is_official INTO _name, _official FROM public.servers WHERE id = _server;
  IF _name IS NULL THEN RAISE EXCEPTION 'Server not found'; END IF;
  IF _official THEN RAISE EXCEPTION 'Yappify HQ is the official server and can''t be a partner'; END IF;
  UPDATE public.servers
     SET is_partner = _partner,
         partnered_at = CASE WHEN _partner THEN COALESCE(partnered_at, now()) ELSE NULL END
   WHERE id = _server;
  PERFORM public.write_audit(CASE WHEN _partner THEN 'server.partner' ELSE 'server.unpartner' END, 'server', _server::text, jsonb_build_object('name', _name));
END; $$;
REVOKE EXECUTE ON FUNCTION public.admin_set_server_partner(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_server_partner(uuid, boolean) TO authenticated;