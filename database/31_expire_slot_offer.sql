BEGIN;

CREATE OR REPLACE FUNCTION hospital.expire_slot_offer(p_offer_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, hospital, pg_temp
AS $$
DECLARE
    target_slot_id bigint;
    released_visit_id bigint;
    moment timestamptz;
BEGIN
    SELECT o.slot_id INTO target_slot_id
    FROM hospital.slot_offers AS o
    WHERE o.offer_id = p_offer_id
      AND o.status = 'Pending'
      AND o.expires_at <= clock_timestamp();

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    -- Use the same slot lock as booking, acceptance and decline.
    PERFORM 1
    FROM hospital.appointment_slots
    WHERE slot_id = target_slot_id
    FOR UPDATE;

    -- Another transaction may have resolved the offer while we waited.
    moment := clock_timestamp();

    UPDATE hospital.slot_offers
    SET status = 'Expired', resolved_at = moment
    WHERE offer_id = p_offer_id
      AND status = 'Pending'
      AND expires_at <= moment
    RETURNING released_appointment_id INTO released_visit_id;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    PERFORM hospital.offer_released_slot(released_visit_id);
    RETURN true;
END;
$$;

ALTER FUNCTION hospital.expire_slot_offer(bigint)
    OWNER TO hospital_routine_owner;

REVOKE ALL ON FUNCTION hospital.expire_slot_offer(bigint) FROM PUBLIC;

COMMIT;