BEGIN;

-- Automatically maintain the last-modified timestamp.
CREATE OR REPLACE FUNCTION hospital.set_appointment_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER appointment_updated_at
BEFORE UPDATE ON hospital.appointments
FOR EACH ROW
EXECUTE FUNCTION hospital.set_appointment_updated_at();


-- Record new bookings and changes.
CREATE OR REPLACE FUNCTION hospital.log_appointment_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO hospital.appointment_audit (
            appointment_id,
            action,
            old_values,
            new_values,
            changed_by,
            changed_at
        )
        VALUES (
            NEW.appointment_id,
            'INSERT',
            NULL,
            to_jsonb(NEW),
            NULL,
            clock_timestamp()
        );

    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO hospital.appointment_audit (
            appointment_id,
            action,
            old_values,
            new_values,
            changed_by,
            changed_at
        )
        VALUES (
            NEW.appointment_id,
            'UPDATE',
            to_jsonb(OLD),
            to_jsonb(NEW),
            NULL,
            clock_timestamp()
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER appointment_change_audit
AFTER INSERT OR UPDATE ON hospital.appointments
FOR EACH ROW
EXECUTE FUNCTION hospital.log_appointment_change();

COMMIT;