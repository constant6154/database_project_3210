BEGIN;

CREATE OR REPLACE FUNCTION hospital.guard_appointment_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS NULL THEN
        RAISE EXCEPTION 'Appointment status is required';
    END IF;

    -- An update that keeps the same status is allowed.
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    IF OLD.status = 'Booked'
       AND NEW.status IN ('Cancelled', 'Completed', 'NoShow') THEN
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'Invalid appointment status transition: % -> %',
        OLD.status, NEW.status;
END;
$$;

DROP TRIGGER IF EXISTS appointment_status_guard
ON hospital.appointments;

CREATE TRIGGER appointment_status_guard
BEFORE UPDATE OF status
ON hospital.appointments
FOR EACH ROW
EXECUTE FUNCTION hospital.guard_appointment_status();

COMMIT;