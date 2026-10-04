ALTER TABLE public.renewal_reminders
  ADD COLUMN delivery_status text NOT NULL DEFAULT 'sent',
  ADD COLUMN attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN attempted_at timestamptz,
  ADD COLUMN recipient_email text,
  ADD COLUMN provider_message_id text,
  ADD COLUMN last_error text,
  ADD CONSTRAINT renewal_reminders_delivery_status_check
    CHECK (delivery_status IN ('sending', 'sent', 'failed')),
  ADD CONSTRAINT renewal_reminders_attempt_count_check
    CHECK (attempt_count >= 0);

CREATE INDEX renewal_reminders_delivery_retry_idx
  ON public.renewal_reminders (delivery_status, attempted_at)
  WHERE delivery_status <> 'sent';
