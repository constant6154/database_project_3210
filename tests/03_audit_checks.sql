BEGIN ISOLATION LEVEL READ COMMITTED;

-- Remember the audit count before testing.
CREATE TEMP TABLE audit_test_baseline ON COMMIT DROP AS
SELECT count(*) AS row_count
FROM hospital.appointment_audit;

DO $$
DECLARE
    v_id bigint;
BEGIN
    -- Create a temporary booking.
    v_id := hospital.book_appointment(
        2, 3, 'Audit logging test'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointment_audit
        WHERE appointment_id = v_id
          AND action = 'INSERT'
          AND old_values IS NULL
          AND new_values ->> 'status' = 'Booked'
    ) THEN
        RAISE EXCEPTION 'FAIL: booking audit record missing';
    END IF;

    RAISE NOTICE 'PASS 1: new booking automatically logged';

    -- Cancel the same booking.
    PERFORM hospital.cancel_appointment(2, v_id);

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointment_audit
        WHERE appointment_id = v_id
          AND action = 'UPDATE'
          AND old_values ->> 'status' = 'Booked'
          AND new_values ->> 'status' = 'Cancelled'
    ) THEN
        RAISE EXCEPTION 'FAIL: cancellation audit record missing';
    END IF;

    IF (
        SELECT count(*)
        FROM hospital.appointment_audit
        WHERE appointment_id = v_id
    ) <> 2 THEN
        RAISE EXCEPTION 'FAIL: expected exactly two audit records';
    END IF;

    RAISE NOTICE 'PASS 2: cancellation logged with old and new status';
END;
$$;

-- Display the history created during this test.
SELECT
    audit_id,
    appointment_id,
    action,
    old_values ->> 'status' AS previous_status,
    new_values ->> 'status' AS new_status
FROM hospital.appointment_audit
ORDER BY audit_id;

-- Undo the test booking, cancellation, and their audit records.
ROLLBACK;

SELECT
    (SELECT count(*) FROM hospital.appointments)
        AS total_appointments,
    (SELECT count(*) FROM hospital.available_slots)
        AS available_slots,
    (SELECT count(*) FROM hospital.appointment_audit)
        AS audit_records;