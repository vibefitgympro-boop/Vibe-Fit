CREATE OR REPLACE FUNCTION private.gym_name_short_code(p_name text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $$
DECLARE
  cleaned_name text;
  prefix text;
BEGIN
  cleaned_name := upper(coalesce(p_name, ''));
  cleaned_name := regexp_replace(cleaned_name, '[^A-Z0-9]+', ' ', 'g');
  cleaned_name := btrim(regexp_replace(cleaned_name, '\s+', ' ', 'g'));

  IF cleaned_name = '' THEN
    RETURN 'GYM';
  END IF;

  IF position(' ' IN cleaned_name) = 0 THEN
    RETURN left(cleaned_name, 3);
  END IF;

  SELECT string_agg(left(word, 1), '')
  INTO prefix
  FROM regexp_split_to_table(cleaned_name, ' ') AS word;

  RETURN coalesce(nullif(left(prefix, 6), ''), 'GYM');
END;
$$;

CREATE OR REPLACE FUNCTION private.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  is_first boolean;
  gym_name text;
  member_prefix text;
BEGIN
  PERFORM pg_advisory_xact_lock(424242);
  SELECT NOT EXISTS (SELECT 1 FROM public.user_roles WHERE role = 'admin') INTO is_first;
  SELECT settings.gym_name
  INTO gym_name
  FROM public.gym_settings AS settings
  ORDER BY settings.updated_at DESC
  LIMIT 1;
  member_prefix := private.gym_name_short_code(gym_name);

  INSERT INTO public.profiles (id, email, display_name, avatar_url)
  VALUES (
    NEW.id,
    COALESCE(NEW.email, ''),
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(COALESCE(NEW.email, ''), '@', 1)),
    NEW.raw_user_meta_data->>'avatar_url'
  );

  IF is_first THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'admin');
  ELSE
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'member');
    INSERT INTO public.members (profile_id, member_code, status, joined_on)
    VALUES (
      NEW.id,
      member_prefix || '-' || upper(substr(replace(NEW.id::text, '-', ''), 1, 8)),
      'lead',
      current_date
    );
  END IF;

  RETURN NEW;
END;
$$;
