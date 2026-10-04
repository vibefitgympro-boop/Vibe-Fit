-- Store only whether the hook was configured through Admin Settings.
-- The Supabase PAT is never persisted; the signing secret lives in Supabase's function/auth configuration.
CREATE TABLE IF NOT EXISTS public.gym_send_email_auth_hook (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  enabled boolean NOT NULL DEFAULT false,
  configured_at timestamptz,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gym_send_email_auth_hook ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.gym_send_email_auth_hook FROM anon, authenticated;
GRANT ALL ON TABLE public.gym_send_email_auth_hook TO service_role;
