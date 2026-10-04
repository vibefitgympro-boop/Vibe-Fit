-- Gmail OAuth data is stored separately from public-facing gym settings.
-- Client secret and refresh token fields contain AES-GCM ciphertext produced on the server.
CREATE TABLE IF NOT EXISTS public.gym_gmail_oauth (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  client_id text NOT NULL,
  client_secret_ciphertext text NOT NULL,
  refresh_token_ciphertext text,
  sender_email text,
  connected_at timestamptz,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gym_gmail_oauth ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.gym_gmail_oauth FROM anon, authenticated;
GRANT ALL ON TABLE public.gym_gmail_oauth TO service_role;
