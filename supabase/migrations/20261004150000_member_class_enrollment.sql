CREATE OR REPLACE FUNCTION public.enroll_member_in_class(
  p_schedule_id uuid,
  p_member_id uuid,
  p_user_id uuid
)
RETURNS TABLE(outcome text, waitlist_position integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_schedule public.class_schedules%ROWTYPE;
  v_member_id uuid;
  v_booking public.class_bookings%ROWTYPE;
  v_waitlist public.class_waitlists%ROWTYPE;
  v_booked_count integer;
  v_waitlist_position integer;
  v_timezone text;
  v_today date;
BEGIN
  SELECT m.id INTO v_member_id
  FROM public.members AS m
  WHERE m.id = p_member_id AND m.profile_id = p_user_id AND m.status = 'active';
  IF v_member_id IS NULL THEN
    RAISE EXCEPTION 'An active member profile is required to enroll in classes';
  END IF;

  SELECT COALESCE((
    SELECT gs.timezone FROM public.gym_settings AS gs ORDER BY gs.updated_at DESC LIMIT 1
  ), 'Asia/Kolkata') INTO v_timezone;
  v_today := (now() AT TIME ZONE v_timezone)::date;
  IF NOT EXISTS (
    SELECT 1 FROM public.memberships AS membership
    WHERE membership.member_id = v_member_id
      AND membership.status = 'active'
      AND membership.starts_on <= v_today
      AND membership.ends_on >= v_today
  ) THEN
    RAISE EXCEPTION 'An active membership is required to enroll in a class';
  END IF;

  SELECT * INTO v_schedule
  FROM public.class_schedules
  WHERE id = p_schedule_id AND status = 'scheduled'
  FOR UPDATE;
  IF NOT FOUND OR v_schedule.starts_at <= now() THEN
    RAISE EXCEPTION 'This class is no longer open for enrollment';
  END IF;

  SELECT * INTO v_booking FROM public.class_bookings
  WHERE schedule_id = p_schedule_id AND member_id = v_member_id;
  SELECT * INTO v_waitlist FROM public.class_waitlists
  WHERE schedule_id = p_schedule_id AND member_id = v_member_id;

  IF v_booking.id IS NOT NULL AND v_booking.status <> 'cancelled' THEN
    RETURN QUERY SELECT 'already_booked'::text, NULL::integer;
    RETURN;
  END IF;

  SELECT count(*)::integer INTO v_booked_count
  FROM public.class_bookings
  WHERE schedule_id = p_schedule_id AND status = 'booked';

  IF v_waitlist.id IS NOT NULL THEN
    SELECT min(position) INTO v_waitlist_position
    FROM public.class_waitlists WHERE schedule_id = p_schedule_id;
    IF v_booked_count < v_schedule.capacity AND v_waitlist.position = v_waitlist_position THEN
      DELETE FROM public.class_waitlists WHERE id = v_waitlist.id;
      IF v_booking.id IS NULL THEN
        INSERT INTO public.class_bookings(schedule_id, member_id, status)
        VALUES (p_schedule_id, v_member_id, 'booked');
      ELSE
        UPDATE public.class_bookings SET status = 'booked', booked_at = now(), cancelled_at = NULL
        WHERE id = v_booking.id;
      END IF;
      RETURN QUERY SELECT 'booked'::text, NULL::integer;
      RETURN;
    END IF;
    RETURN QUERY SELECT 'waitlisted'::text, v_waitlist.position;
    RETURN;
  END IF;

  IF v_booked_count < v_schedule.capacity AND NOT EXISTS (
    SELECT 1 FROM public.class_waitlists WHERE schedule_id = p_schedule_id
  ) THEN
    IF v_booking.id IS NULL THEN
      INSERT INTO public.class_bookings(schedule_id, member_id, status)
      VALUES (p_schedule_id, v_member_id, 'booked');
    ELSE
      UPDATE public.class_bookings SET status = 'booked', booked_at = now(), cancelled_at = NULL
      WHERE id = v_booking.id;
    END IF;
    RETURN QUERY SELECT 'booked'::text, NULL::integer;
    RETURN;
  END IF;

  SELECT COALESCE(max(position), 0) + 1 INTO v_waitlist_position
  FROM public.class_waitlists WHERE schedule_id = p_schedule_id;
  INSERT INTO public.class_waitlists(schedule_id, member_id, position)
  VALUES (p_schedule_id, v_member_id, v_waitlist_position);
  RETURN QUERY SELECT 'waitlisted'::text, v_waitlist_position;
END;
$$;

REVOKE ALL ON FUNCTION public.enroll_member_in_class(uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enroll_member_in_class(uuid, uuid, uuid) TO service_role;
