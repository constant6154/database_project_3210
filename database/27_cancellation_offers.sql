-- Run as postgres on hospital_db. This migration does not cancel any visits.
BEGIN;
GRANT SELECT, UPDATE (status) ON hospital.waitlist_requests TO hospital_routine_owner;
GRANT SELECT, INSERT, UPDATE (status, resolved_at) ON hospital.slot_offers TO hospital_routine_owner;

-- A browser may still display an old availability card. Enforce the hold at
-- insertion time as well. The booking routine already locks this slot first.
CREATE OR REPLACE FUNCTION hospital.guard_offered_slot() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, hospital, pg_temp AS $$
BEGIN
    PERFORM 1 FROM hospital.appointment_slots
    WHERE slot_id = NEW.slot_id FOR UPDATE;
    IF EXISTS (
        SELECT 1 FROM hospital.slot_offers
        WHERE slot_id = NEW.slot_id AND status = 'Pending'
          AND expires_at > clock_timestamp()
    ) THEN
        RAISE EXCEPTION 'Slot is reserved for an earlier-visit offer';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION hospital.offer_after_cancellation() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, hospital, pg_temp AS $$
DECLARE
    s hospital.appointment_slots%ROWTYPE;
    candidate bigint;
    moment timestamptz;
    offered_id bigint;
BEGIN
    -- Close requests tied to the visit that just lost its Booked status.
    UPDATE hospital.waitlist_requests
       SET status = 'Withdrawn'
     WHERE original_appointment_id = NEW.appointment_id AND status = 'Active';
    UPDATE hospital.slot_offers AS o
       SET status = 'Withdrawn', resolved_at = clock_timestamp()
      FROM hospital.waitlist_requests AS w
     WHERE w.original_appointment_id = NEW.appointment_id
       AND w.request_id = o.request_id AND o.status = 'Pending';

    SELECT * INTO STRICT s FROM hospital.appointment_slots
    WHERE slot_id = NEW.slot_id FOR UPDATE;
    IF s.is_blocked OR s.starts_at <= clock_timestamp() THEN RETURN NEW; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM hospital.doctors d JOIN hospital.users u USING (user_id)
        WHERE d.doctor_id = s.doctor_id AND u.is_active
    ) THEN RETURN NEW; END IF;

    UPDATE hospital.slot_offers SET status = 'Expired', resolved_at = clock_timestamp()
    WHERE slot_id = s.slot_id AND status = 'Pending' AND expires_at <= clock_timestamp();

    -- A request can already have a live offer on another slot. If another
    -- cancellation wins that request concurrently, continue to the next one.
    FOR candidate IN
        SELECT w.request_id
        FROM hospital.waitlist_requests w
        JOIN hospital.appointments a ON a.appointment_id = w.original_appointment_id
        JOIN hospital.appointment_slots orig ON orig.slot_id = a.slot_id
        JOIN hospital.patients p ON p.patient_id = a.patient_id
        JOIN hospital.users u ON u.user_id = p.user_id
        WHERE w.status = 'Active' AND a.status = 'Booked' AND u.is_active
          AND a.patient_id <> NEW.patient_id
          AND orig.doctor_id = s.doctor_id AND orig.starts_at > s.starts_at
          AND (s.starts_at AT TIME ZONE 'Asia/Dhaka')::date
              BETWEEN w.earliest_date AND w.latest_date
          AND NOT EXISTS (
              SELECT 1 FROM hospital.appointments other
              JOIN hospital.appointment_slots os ON os.slot_id = other.slot_id
              WHERE other.patient_id = a.patient_id AND other.status <> 'Cancelled'
                AND os.starts_at < s.ends_at AND os.ends_at > s.starts_at
          )
        ORDER BY w.requested_at, w.request_id
        FOR UPDATE OF w
    LOOP
        moment := clock_timestamp();
        IF moment >= s.starts_at THEN EXIT; END IF;
        UPDATE hospital.slot_offers SET status = 'Expired', resolved_at = moment
        WHERE request_id = candidate AND status = 'Pending' AND expires_at <= moment;
        INSERT INTO hospital.slot_offers
            (request_id, slot_id, released_appointment_id, offered_at, expires_at)
        VALUES (candidate, s.slot_id, NEW.appointment_id, moment,
                least(moment + interval '24 hours', s.starts_at))
        ON CONFLICT DO NOTHING
        RETURNING offer_id INTO offered_id;
        IF offered_id IS NOT NULL THEN EXIT; END IF;
    END LOOP;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION hospital.guard_offered_slot(),
    hospital.offer_after_cancellation() FROM PUBLIC;

CREATE TRIGGER guard_offered_slot BEFORE INSERT ON hospital.appointments
FOR EACH ROW WHEN (NEW.status <> 'Cancelled')
EXECUTE FUNCTION hospital.guard_offered_slot();

CREATE TRIGGER offer_after_cancellation AFTER UPDATE OF status ON hospital.appointments
FOR EACH ROW WHEN (OLD.status = 'Booked' AND NEW.status = 'Cancelled')
EXECUTE FUNCTION hospital.offer_after_cancellation();

CREATE OR REPLACE VIEW hospital.available_slots AS
SELECT s.slot_id, d.doctor_id, d.full_name AS doctor_name, dep.name AS department,
       d.consultation_fee, s.starts_at, s.ends_at
FROM hospital.appointment_slots s
JOIN hospital.doctors d ON d.doctor_id = s.doctor_id
JOIN hospital.departments dep ON dep.department_id = d.department_id
JOIN hospital.users u ON u.user_id = d.user_id
WHERE u.is_active AND NOT s.is_blocked AND s.starts_at > CURRENT_TIMESTAMP
  AND NOT EXISTS (
      SELECT 1 FROM hospital.appointments a
      WHERE a.slot_id = s.slot_id AND a.status <> 'Cancelled'
  )
  AND NOT EXISTS (
      SELECT 1 FROM hospital.slot_offers o
      WHERE o.slot_id = s.slot_id AND o.status = 'Pending'
        AND o.expires_at > CURRENT_TIMESTAMP
  );
COMMIT;
