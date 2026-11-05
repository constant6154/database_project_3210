BEGIN;

CREATE TEMP TABLE doctor_permission_fixture (
    complete_id bigint,
    no_show_id bigint,
    test_day date
) ON COMMIT DROP;

DO $$
DECLARE
    v_past timestamptz;
    v_day date;
    v_slot bigint;
    v_complete bigint;
    v_no_show bigint;
BEGIN
    SELECT LEAST(
        COALESCE(MIN(starts_at), clock_timestamp()),
        clock_timestamp()
    ) - interval '3 days'
    INTO v_past
    FROM hospital.appointment_slots;

    INSERT INTO hospital.appointment_slots (
        doctor_id, starts_at, ends_at
    )
    VALUES (1, v_past, v_past + interval '30 minutes')
    RETURNING slot_id INTO v_slot;

    INSERT INTO hospital.appointments (
        patient_id, slot_id, status, booked_fee
    )
    VALUES (2, v_slot, 'Booked', 800)
    RETURNING appointment_id INTO v_complete;

    INSERT INTO hospital.appointment_slots (
        doctor_id, starts_at, ends_at
    )
    VALUES (
        1,
        v_past + interval '1 hour',
        v_past + interval '90 minutes'
    )
    RETURNING slot_id INTO v_slot;

    INSERT INTO hospital.appointments (
        patient_id, slot_id, status, booked_fee
    )
    VALUES (2, v_slot, 'Booked', 800)
    RETURNING appointment_id INTO v_no_show;

    -- Choose a date beyond all existing slots.
    SELECT (
        GREATEST(
            COALESCE(MAX(ends_at), clock_timestamp()),
            clock_timestamp()
        ) AT TIME ZONE 'Asia/Dhaka'
    )::date + 7
    INTO v_day
    FROM hospital.appointment_slots;

    -- A one-day schedule guarantees slots for this test.
    INSERT INTO hospital.doctor_schedules (
        doctor_id, weekday, start_time, end_time,
        slot_minutes, valid_from, valid_until, is_active
    )
    VALUES (
        1, EXTRACT(ISODOW FROM v_day)::smallint,
        '12:00', '13:00', 30, v_day, v_day, true
    );

    INSERT INTO doctor_permission_fixture
    VALUES (v_complete, v_no_show, v_day);
END;
$$;

GRANT SELECT ON doctor_permission_fixture TO hospital_app;

SET LOCAL ROLE hospital_app;

DO $$
DECLARE
    v_fixture record;
    v_count integer;
    v_slot bigint;
BEGIN
    IF current_user <> 'hospital_app' THEN
        RAISE EXCEPTION 'FAIL: wrong test role';
    END IF;

    SELECT * INTO STRICT v_fixture
    FROM pg_temp.doctor_permission_fixture;

    CALL hospital.complete_consultation(
        1, v_fixture.complete_id,
        'Permission test diagnosis', 'Temporary test'
    );

    RAISE NOTICE 'PASS 1: consultation procedure executed';

    IF hospital.mark_no_show(
        1, v_fixture.no_show_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: no-show operation failed';
    END IF;

    RAISE NOTICE 'PASS 2: no-show function executed';

    v_count := hospital.generate_slots(
        1, v_fixture.test_day, v_fixture.test_day
    );

    IF v_count < 2 THEN
        RAISE EXCEPTION 'FAIL: expected at least two generated slots';
    END IF;

    IF hospital.generate_slots(
        1, v_fixture.test_day, v_fixture.test_day
    ) <> 0 THEN
        RAISE EXCEPTION 'FAIL: repeated generation added slots';
    END IF;

    RAISE NOTICE 'PASS 3: generation works without duplicates';

    SELECT slot_id INTO v_slot
    FROM hospital.available_slots
    WHERE doctor_id = 1
      AND starts_at = (
          (v_fixture.test_day + time '12:00')
          AT TIME ZONE 'Asia/Dhaka'
      );

    IF v_slot IS NULL THEN
        RAISE EXCEPTION 'FAIL: generated noon slot missing';
    END IF;

    IF hospital.set_slot_blocked(1, v_slot, true)
       IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: blocking failed';
    END IF;

    IF EXISTS (
        SELECT 1 FROM hospital.available_slots
        WHERE slot_id = v_slot
    ) THEN
        RAISE EXCEPTION 'FAIL: blocked slot is still available';
    END IF;

    IF hospital.set_slot_blocked(1, v_slot, false)
       IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL: unblocking failed';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM hospital.available_slots
        WHERE slot_id = v_slot
    ) THEN
        RAISE EXCEPTION 'FAIL: unblocked slot is not available';
    END IF;

    RAISE NOTICE 'PASS 4: blocking and unblocking work';

    BEGIN
        UPDATE hospital.appointment_slots
        SET is_blocked = true
        WHERE false;

        RAISE EXCEPTION 'FAIL: direct slot update allowed';
    EXCEPTION
        WHEN insufficient_privilege THEN
            RAISE NOTICE 'PASS 5: direct slot updates denied';
    END;
END;
$$;

RESET ROLE;

-- Verify saved results using the administrator's read access.
DO $$
DECLARE
    v_fixture record;
BEGIN
    SELECT * INTO STRICT v_fixture
    FROM pg_temp.doctor_permission_fixture;

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments AS a
        JOIN hospital.consultations AS c
          ON c.appointment_id = a.appointment_id
        WHERE a.appointment_id = v_fixture.complete_id
          AND a.status = 'Completed'
          AND c.diagnosis = 'Permission test diagnosis'
    ) THEN
        RAISE EXCEPTION 'FAIL: consultation result missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM hospital.appointments
        WHERE appointment_id = v_fixture.no_show_id
          AND status = 'NoShow'
    ) THEN
        RAISE EXCEPTION 'FAIL: NoShow status missing';
    END IF;

    RAISE NOTICE 'PASS 6: consultation and no-show results verified';
END;
$$;

ROLLBACK;