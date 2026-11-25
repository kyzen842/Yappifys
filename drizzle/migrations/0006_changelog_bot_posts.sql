CREATE OR REPLACE FUNCTION public.admin_post_changelog(_version text, _notes text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE cid uuid; mid uuid; v text;
BEGIN
  PERFORM public.require_admin();
  v := regexp_replace(trim(_version), '^[vV]', '');
  IF v = '' THEN RAISE EXCEPTION 'Add a version number'; END IF;
  IF coalesce(trim(_notes), '') = '' THEN RAISE EXCEPTION 'Describe what''s in the update'; END IF;
  SELECT id INTO cid FROM public.channels WHERE server_id = '00000000-0000-0000-0000-000000000001' AND slug = 'changelog';
  INSERT INTO public.messages (channel_id, author_id, content)
  VALUES (cid, NULL, '🚀 **Yappify v' || v || '** is out!' || chr(10) || trim(_notes))
  RETURNING id INTO mid;
  PERFORM public.write_audit('changelog.post', 'version', v, jsonb_build_object('notes', left(_notes, 300)));
  RETURN mid;
END; $$;
REVOKE EXECUTE ON FUNCTION public.admin_post_changelog(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_post_changelog(text, text) TO authenticated;
