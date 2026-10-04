CREATE INDEX IF NOT EXISTS idx_payment_events_payment_id ON public.payment_events(payment_id);
CREATE INDEX IF NOT EXISTS idx_attendance_checked_in_at ON public.attendance(checked_in_at);
CREATE INDEX IF NOT EXISTS idx_trainer_assignments_schedule_id ON public.trainer_assignments(schedule_id);

CREATE OR REPLACE FUNCTION public.delete_archived_gym_data(
  p_dataset text,
  p_before timestamptz,
  p_exported_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted jsonb := '{}'::jsonb;
  v_payments integer := 0;
  v_payment_events integer := 0;
  v_attendance integer := 0;
  v_bookings integer := 0;
  v_waitlists integer := 0;
  v_assignments integer := 0;
  v_schedules integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only administrators can delete archived gym data';
  END IF;
  IF p_before IS NULL OR p_exported_at IS NULL OR p_before > now() OR p_exported_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'Invalid archive cutoff or export timestamp';
  END IF;

  IF p_dataset = 'payments' THEN
    DELETE FROM public.payment_events AS event
    USING public.payments AS payment
    WHERE event.payment_id = payment.id
      AND payment.created_at < p_before
      AND payment.created_at <= p_exported_at
      AND event.created_at <= p_exported_at;
    GET DIAGNOSTICS v_payment_events = ROW_COUNT;

    DELETE FROM public.payments
    WHERE created_at < p_before AND created_at <= p_exported_at;
    GET DIAGNOSTICS v_payments = ROW_COUNT;
    v_deleted := jsonb_build_object('payments', v_payments, 'paymentEvents', v_payment_events);
  ELSIF p_dataset = 'attendance' THEN
    DELETE FROM public.attendance
    WHERE checked_in_at < p_before AND created_at <= p_exported_at;
    GET DIAGNOSTICS v_attendance = ROW_COUNT;
    v_deleted := jsonb_build_object('attendance', v_attendance);
  ELSIF p_dataset = 'classes' THEN
    SELECT count(*) INTO v_schedules
    FROM public.class_schedules
    WHERE starts_at < p_before AND created_at <= p_exported_at;

    DELETE FROM public.trainer_assignments AS assignment
    USING public.class_schedules AS schedule
    WHERE assignment.schedule_id = schedule.id
      AND schedule.starts_at < p_before AND schedule.created_at <= p_exported_at
      AND assignment.created_at <= p_exported_at;
    GET DIAGNOSTICS v_assignments = ROW_COUNT;

    DELETE FROM public.class_waitlists AS waitlist
    USING public.class_schedules AS schedule
    WHERE waitlist.schedule_id = schedule.id
      AND schedule.starts_at < p_before AND schedule.created_at <= p_exported_at
      AND waitlist.joined_at <= p_exported_at;
    GET DIAGNOSTICS v_waitlists = ROW_COUNT;

    DELETE FROM public.class_bookings AS booking
    USING public.class_schedules AS schedule
    WHERE booking.schedule_id = schedule.id
      AND schedule.starts_at < p_before AND schedule.created_at <= p_exported_at
      AND booking.booked_at <= p_exported_at;
    GET DIAGNOSTICS v_bookings = ROW_COUNT;

    v_deleted := jsonb_build_object(
      'schedulesRetained', v_schedules,
      'bookings', v_bookings,
      'waitlists', v_waitlists,
      'trainerAssignments', v_assignments
    );
  ELSE
    RAISE EXCEPTION 'Unsupported archive dataset';
  END IF;

  RETURN jsonb_build_object('dataset', p_dataset, 'deleted', v_deleted);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_archived_gym_data(text, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_archived_gym_data(text, timestamptz, timestamptz) TO authenticated;
