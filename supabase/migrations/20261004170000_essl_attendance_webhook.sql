CREATE TABLE IF NOT EXISTS public.essl_webhook_config (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  token_hash text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.essl_webhook_config ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.essl_webhook_config TO service_role;

CREATE TABLE IF NOT EXISTS public.essl_member_mappings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id uuid NOT NULL REFERENCES public.access_devices(id) ON DELETE CASCADE,
  member_id uuid NOT NULL REFERENCES public.members(id) ON DELETE CASCADE,
  device_user_id text NOT NULL CHECK (length(btrim(device_user_id)) BETWEEN 1 AND 100),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (device_id, device_user_id)
);
CREATE INDEX IF NOT EXISTS essl_member_mappings_member_idx ON public.essl_member_mappings (member_id);
CREATE INDEX IF NOT EXISTS essl_member_mappings_device_active_idx ON public.essl_member_mappings (device_id, active);
ALTER TABLE public.essl_member_mappings ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.essl_member_mappings TO service_role;
DROP POLICY IF EXISTS essl_member_mappings_admin_all ON public.essl_member_mappings;
CREATE POLICY essl_member_mappings_admin_all ON public.essl_member_mappings
  FOR ALL TO authenticated
  USING (private.has_role(auth.uid(), 'admin'::public.app_role))
  WITH CHECK (private.has_role(auth.uid(), 'admin'::public.app_role));
DROP TRIGGER IF EXISTS essl_member_mappings_updated ON public.essl_member_mappings;
CREATE TRIGGER essl_member_mappings_updated
  BEFORE UPDATE ON public.essl_member_mappings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
