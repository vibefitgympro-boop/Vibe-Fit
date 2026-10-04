-- Payment gateway credentials are kept separate from general gym settings.
-- Values are encrypted by the application before they are written to the database.
CREATE TABLE IF NOT EXISTS public.gym_payment_gateway_credentials (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  razorpay_key_id_ciphertext text,
  razorpay_key_secret_ciphertext text,
  stripe_secret_key_ciphertext text,
  stripe_webhook_secret_ciphertext text,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.gym_payment_gateway_credentials ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.gym_payment_gateway_credentials FROM anon, authenticated;
GRANT ALL ON TABLE public.gym_payment_gateway_credentials TO service_role;
