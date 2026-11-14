BEGIN;

CREATE OR REPLACE FUNCTION hospital.process_due_slot_offers()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, hospital, pg_temp
AS $$
DECLARE
    due_offer_id bigint;
    processed integer := 0;
BEGIN
    FOR due_offer_id IN
        SELECT o.offer_id
        FROM hospital.slot_offers AS o
        WHERE o.status = 'Pending'
          AND o.expires_at <= statement_timestamp()
        ORDER BY o.slot_id, o.offer_id
    LOOP
        IF hospital.expire_slot_offer(due_offer_id) THEN
            processed := processed + 1;
        END IF;
    END LOOP;

    RETURN processed;
END;
$$;

ALTER FUNCTION hospital.process_due_slot_offers()
    OWNER TO hospital_routine_owner;

REVOKE ALL ON FUNCTION hospital.process_due_slot_offers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hospital.process_due_slot_offers() TO hospital_app;

COMMIT;