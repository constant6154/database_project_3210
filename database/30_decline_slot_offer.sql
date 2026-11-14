BEGIN;

-- Called after a cancellation or after a patient declines a live offer.
-- The released appointment identifies both the slot and the cancelling patient.
CREATE OR REPLACE FUNCTION hospital.offer_released_slot(
    p_released_appointment_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, hospital, pg_temp
AS $$
DECLARE
    released hospital.appointments%ROWTYPE;
    s hospital.appointment_slots%ROWTYPE;
    candidate bigint;
    moment timestamptz;
    new_offer_id bigint;
BEGIN
    SELECT a.* INTO STRICT released
    FROM hospital.appointments AS a
    WHERE a.appointment_id = p_released_appointment_id;

    IF released.status <> 'Cancelled' THEN
        RETURN NULL;
    END IF;

    SELECT slot.* INTO STRICT s
    FROM hospital.appointment_slots AS slot
    WHERE slot.slot_id = released.slot_id
    FOR UPDATE;

    moment := clock_timestamp();

    IF s.is_blocked OR s.starts_at <= moment THEN
        RETURN NULL;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.doctors AS d
        JOIN hospital.users AS u ON u.user_id = d.user_id
        WHERE d.doctor_id = s.doctor_id AND u.is_active
    ) THEN
        RETURN NULL;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM hospital.appointments AS a
        WHERE a.slot_id = s.slot_id AND a.status <> 'Cancelled'
    ) THEN
        RETURN NULL;
    END IF;

    -- Retain migration 27's cleanup when processing this slot.
    UPDATE hospital.slot_offers
    SET status = 'Expired', resolved_at = moment
    WHERE slot_id = s.slot_id
      AND status = 'Pending'
      AND expires_at <= moment;

    IF EXISTS (
        SELECT 1
        FROM hospital.slot_offers AS o
        WHERE o.slot_id = s.slot_id AND o.status = 'Pending'
    ) THEN
        RETURN NULL;
    END IF;

    FOR candidate IN
        SELECT w.request_id
        FROM hospital.waitlist_requests AS w
        JOIN hospital.appointments AS a
          ON a.appointment_id = w.original_appointment_id
        JOIN hospital.appointment_slots AS orig ON orig.slot_id = a.slot_id
        JOIN hospital.patients AS p ON p.patient_id = a.patient_id
        JOIN hospital.users AS u ON u.user_id = p.user_id
        WHERE w.status = 'Active'
          AND a.status = 'Booked'
          AND u.is_active
          AND NOT EXISTS (
              SELECT 1
              FROM hospital.slot_offers AS held
              WHERE held.request_id = w.request_id
                AND held.status = 'Pending'
          )
          AND a.patient_id <> released.patient_id
          AND orig.doctor_id = s.doctor_id
          AND orig.starts_at > s.starts_at
          AND (s.starts_at AT TIME ZONE 'Asia/Dhaka')::date
              BETWEEN w.earliest_date AND w.latest_date
          AND NOT EXISTS (
              SELECT 1
              FROM hospital.slot_offers AS previous
              WHERE previous.request_id = w.request_id
                AND previous.released_appointment_id = released.appointment_id
          )
          AND NOT EXISTS (
              SELECT 1
              FROM hospital.appointments AS other
              JOIN hospital.appointment_slots AS os ON os.slot_id = other.slot_id
              WHERE other.patient_id = a.patient_id
                AND other.status <> 'Cancelled'
                AND os.starts_at < s.ends_at
                AND os.ends_at > s.starts_at
          )
        ORDER BY w.requested_at, w.request_id
        FOR UPDATE OF w
    LOOP
        moment := clock_timestamp();

        IF moment >= s.starts_at THEN
            RETURN NULL;
        END IF;

        INSERT INTO hospital.slot_offers (
            request_id, slot_id, released_appointment_id, offered_at, expires_at
        )
        VALUES (
            candidate, s.slot_id, released.appointment_id, moment,
            LEAST(moment + interval '24 hours', s.starts_at)
        )
        ON CONFLICT DO NOTHING
        RETURNING offer_id INTO new_offer_id;

        IF FOUND THEN
            RETURN new_offer_id;
        END IF;
    END LOOP;

    RETURN NULL;
END;
$$;

ALTER FUNCTION hospital.offer_released_slot(bigint)
    OWNER TO hospital_routine_owner;
REVOKE ALL ON FUNCTION hospital.offer_released_slot(bigint) FROM PUBLIC;

-- The existing trigger already calls this function.
CREATE OR REPLACE FUNCTION hospital.offer_after_cancellation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, hospital, pg_temp
AS $$
BEGIN
    UPDATE hospital.waitlist_requests
    SET status = 'Withdrawn'
    WHERE original_appointment_id = NEW.appointment_id
      AND status = 'Active';

    UPDATE hospital.slot_offers AS o
    SET status = 'Withdrawn', resolved_at = clock_timestamp()
    FROM hospital.waitlist_requests AS w
    WHERE w.original_appointment_id = NEW.appointment_id
      AND w.request_id = o.request_id
      AND o.status = 'Pending';

    PERFORM hospital.offer_released_slot(NEW.appointment_id);
    RETURN NEW;
END;
$$;

-- Flask supplies p_user_id from the signed-in session.
CREATE OR REPLACE FUNCTION hospital.decline_slot_offer(
    p_user_id integer,
    p_offer_id bigint
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, hospital, pg_temp
AS $$
DECLARE
    target_slot_id bigint;
    target hospital.slot_offers%ROWTYPE;
    moment timestamptz;
BEGIN
    SELECT o.slot_id INTO target_slot_id
    FROM hospital.slot_offers AS o
    JOIN hospital.waitlist_requests AS w ON w.request_id = o.request_id
    JOIN hospital.appointments AS a
      ON a.appointment_id = w.original_appointment_id
    JOIN hospital.patients AS p ON p.patient_id = a.patient_id
    WHERE o.offer_id = p_offer_id AND p.user_id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Offer unavailable for this account';
    END IF;

    -- Lock the slot before the offer, like the acceptance path.
    PERFORM 1 FROM hospital.appointment_slots
    WHERE slot_id = target_slot_id
    FOR UPDATE;

    SELECT o.* INTO STRICT target
    FROM hospital.slot_offers AS o
    WHERE o.offer_id = p_offer_id
    FOR UPDATE;

    -- A repeated click returns the same result without another handoff.
    IF target.status IN ('Declined', 'Expired') THEN
        RETURN target.status;
    END IF;

    IF target.status <> 'Pending' THEN
        RAISE EXCEPTION 'This offer is already closed';
    END IF;

    moment := clock_timestamp();

    IF target.expires_at <= moment THEN
        UPDATE hospital.slot_offers
        SET status = 'Expired', resolved_at = moment
        WHERE offer_id = target.offer_id;

        PERFORM hospital.offer_released_slot(target.released_appointment_id);
        RETURN 'Expired';
    END IF;

    UPDATE hospital.slot_offers
    SET status = 'Declined', resolved_at = moment
    WHERE offer_id = target.offer_id;

    PERFORM hospital.offer_released_slot(target.released_appointment_id);
    RETURN 'Declined';
END;
$$;

ALTER FUNCTION hospital.decline_slot_offer(integer, bigint)
    OWNER TO hospital_routine_owner;
REVOKE ALL ON FUNCTION hospital.decline_slot_offer(integer, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hospital.decline_slot_offer(integer, bigint)
    TO hospital_app;

COMMIT;