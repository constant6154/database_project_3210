BEGIN;

GRANT UPDATE (replacement_appointment_id)
ON hospital.slot_offers TO hospital_routine_owner;

CREATE OR REPLACE FUNCTION hospital.accept_slot_offer(
    p_user_id bigint,
    p_offer_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    visit record;
    offer hospital.slot_offers%ROWTYPE;
    replacement bigint;
    accepted_at timestamptz;
BEGIN
    -- Find the original visit through the signed-in patient's account.
    SELECT
        p.patient_id,
        a.appointment_id,
        a.slot_id AS old_slot,
        o.slot_id AS new_slot,
        w.request_id
    INTO visit
    FROM hospital.slot_offers AS o
    JOIN hospital.waitlist_requests AS w ON w.request_id = o.request_id
    JOIN hospital.appointments AS a ON a.appointment_id = w.original_appointment_id
    JOIN hospital.patients AS p ON p.patient_id = a.patient_id
    JOIN hospital.users AS u ON u.user_id = p.user_id
    WHERE o.offer_id = p_offer_id
      AND u.user_id = p_user_id
      AND u.is_active
    FOR UPDATE OF p;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Offer unavailable for this account';
    END IF;

    -- Lock both slots in the same order as the reschedule function.
    PERFORM s.slot_id
    FROM hospital.appointment_slots AS s
    WHERE s.slot_id IN (visit.old_slot, visit.new_slot)
    ORDER BY s.slot_id
    FOR UPDATE;

    PERFORM 1
    FROM hospital.waitlist_requests AS w
    WHERE w.request_id = visit.request_id
    FOR UPDATE;

    SELECT o.*
    INTO STRICT offer
    FROM hospital.slot_offers AS o
    WHERE o.offer_id = p_offer_id
    FOR UPDATE;

    -- A second click returns the booking created by the first click.
    IF offer.status = 'Accepted' THEN
        RETURN offer.replacement_appointment_id;
    END IF;

    accepted_at := clock_timestamp();

    IF offer.status <> 'Pending' OR accepted_at >= offer.expires_at THEN
        RAISE EXCEPTION 'Earlier-visit offer is no longer available';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.waitlist_requests AS w
        JOIN hospital.appointments AS a
          ON a.appointment_id = w.original_appointment_id
        WHERE w.request_id = visit.request_id
          AND w.status = 'Active'
          AND a.status = 'Booked'
          AND a.slot_id = visit.old_slot
    ) THEN
        RAISE EXCEPTION 'Original appointment is no longer eligible';
    END IF;

    -- Cancelling the old visit inside reschedule fires the existing
    -- trigger, which marks its request and pending offer as Withdrawn.
    -- Both slot locks stay held while the replacement is booked.
    replacement := hospital.reschedule_appointment(
        visit.patient_id,
        visit.appointment_id,
        visit.new_slot
    );

    UPDATE hospital.slot_offers
    SET status = 'Accepted',
        resolved_at = accepted_at,
        replacement_appointment_id = replacement
    WHERE offer_id = p_offer_id
      AND status = 'Withdrawn';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Offer could not be finalized';
    END IF;

    UPDATE hospital.waitlist_requests
    SET status = 'Fulfilled'
    WHERE request_id = visit.request_id
      AND status = 'Withdrawn';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request could not be fulfilled';
    END IF;

    RETURN replacement;
END;
$$;

ALTER FUNCTION hospital.accept_slot_offer(bigint, bigint)
    OWNER TO hospital_routine_owner;

REVOKE ALL ON FUNCTION hospital.accept_slot_offer(bigint, bigint)
    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION hospital.accept_slot_offer(bigint, bigint)
    TO hospital_app;

COMMIT;