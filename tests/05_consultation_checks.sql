BEGIN ISOLATION LEVEL READ COMMITTED;

DO $$
DECLARE
    v_start timestamptz;
    v_slot_id bigint;
    v_appointment_id bigint;
    v_rejected boolean := false;
BEGIN
    -- Create a fictional past slot before all existing doctor-1 slots.
    SELECT LEAST(
        clock_timestamp() - interval '2 days',
        COALESCE(min(starts_at), clock_timestamp()) - interval '2 days'
    )
    INTO v_start
    FROM hospital.appointment_slots
    WHERE doctor_id = 1;

    INSERT INTO hospital.appointment_slots (
        doctor_id, starts_at, ends_at
    )
    VALUES (1, v_start, v_start + interval '30 minutes')
    RETURNING slot_id INTO v_slot_id;

    -- Test fixture only: the booking function correctly rejects past slots.
    INSERT INTO hospital.appointments (
        patient_id, slot_id, reason, booked_fee
    )
    VALUES (2, v_slot_id, 'Temporary consultation test', 800)
    RETURNING appointment_id INTO v_appointment_id;

    -- Doctor 2 must not complete doctor 1's appointment.
    BEGIN
        CALL hospital.complete_consultation(
            2, v_appointment_id, 'Demo diagnosis', NULL
        );
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'Appointment is assigned to another doctor' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: wrong doctor accepted';
    END IF;

    RAISE NOTICE 'PASS 1: wrong doctor rejected';

    -- Assigned doctor completes the visit.
    CALL hospital.complete_consultation(
        1, v_appointment_id,
        'Fictional test diagnosis',
        'Fictional test notes'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments AS a
        JOIN hospital.consultations AS c
            ON c.appointment_id = a.appointment_id
        WHERE a.appointment_id = v_appointment_id
          AND a.status = 'Completed'
          AND c.diagnosis = 'Fictional test diagnosis'
          AND c.clinical_notes = 'Fictional test notes'
    ) THEN
        RAISE EXCEPTION 'FAIL: consultation and completion not saved together';
    END IF;

    RAISE NOTICE 'PASS 2: consultation saved and appointment completed';

    -- A completed appointment cannot be completed again.
    v_rejected := false;

    BEGIN
        CALL hospital.complete_consultation(
            1, v_appointment_id, 'Repeated completion', NULL
        );
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'Only booked appointments can be completed' THEN
            v_rejected := true;
        ELSE
            RAISE;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'FAIL: repeated completion accepted';
    END IF;

    RAISE NOTICE 'PASS 3: repeated completion rejected';
END;
$$;

-- Remove all fictional test data and its audit records.
ROLLBACK;

SELECT count(*) AS consultations_after_rollback
FROM hospital.consultations;