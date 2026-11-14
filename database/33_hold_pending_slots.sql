BEGIN;

CREATE OR REPLACE FUNCTION hospital.guard_offered_slot()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, hospital, pg_temp
AS $$
BEGIN
    PERFORM 1
    FROM hospital.appointment_slots
    WHERE slot_id = NEW.slot_id
    FOR UPDATE;

    IF EXISTS (
        SELECT 1
        FROM hospital.slot_offers
        WHERE slot_id = NEW.slot_id
          AND status = 'Pending'
    ) THEN
        RAISE EXCEPTION 'Slot is reserved for an earlier-visit offer';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE VIEW hospital.available_slots AS
SELECT
    s.slot_id,
    d.doctor_id,
    d.full_name AS doctor_name,
    dep.name AS department,
    d.consultation_fee,
    s.starts_at,
    s.ends_at
FROM hospital.appointment_slots AS s
JOIN hospital.doctors AS d ON d.doctor_id = s.doctor_id
JOIN hospital.departments AS dep ON dep.department_id = d.department_id
JOIN hospital.users AS u ON u.user_id = d.user_id
WHERE u.is_active
  AND NOT s.is_blocked
  AND s.starts_at > CURRENT_TIMESTAMP
  AND NOT EXISTS (
      SELECT 1
      FROM hospital.appointments AS a
      WHERE a.slot_id = s.slot_id
        AND a.status <> 'Cancelled'
  )
  AND NOT EXISTS (
      SELECT 1
      FROM hospital.slot_offers AS o
      WHERE o.slot_id = s.slot_id
        AND o.status = 'Pending'
  );

COMMIT;