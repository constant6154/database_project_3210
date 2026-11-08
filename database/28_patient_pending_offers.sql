BEGIN;

CREATE OR REPLACE FUNCTION hospital.patient_pending_offers(p_user_id bigint)
RETURNS TABLE (
    appointment_id bigint,
    offer_id bigint,
    offered_start timestamptz,
    offered_end timestamptz,
    expires_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT
        a.appointment_id,
        o.offer_id,
        s.starts_at,
        s.ends_at,
        o.expires_at
    FROM hospital.slot_offers AS o
    JOIN hospital.waitlist_requests AS w ON w.request_id = o.request_id
    JOIN hospital.appointments AS a ON a.appointment_id = w.original_appointment_id
    JOIN hospital.patients AS p ON p.patient_id = a.patient_id
    JOIN hospital.users AS u ON u.user_id = p.user_id
    JOIN hospital.appointment_slots AS s ON s.slot_id = o.slot_id
    WHERE p.user_id = p_user_id
      AND u.is_active
      AND a.status = 'Booked'
      AND w.status = 'Active'
      AND o.status = 'Pending'
      AND o.expires_at > CURRENT_TIMESTAMP
      AND s.starts_at > CURRENT_TIMESTAMP
      AND NOT s.is_blocked;
$$;

ALTER FUNCTION hospital.patient_pending_offers(bigint)
    OWNER TO hospital_routine_owner;
REVOKE ALL ON FUNCTION hospital.patient_pending_offers(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hospital.patient_pending_offers(bigint) TO hospital_app;

COMMIT;