BEGIN;

CREATE OR REPLACE FUNCTION hospital.generate_slots(
    p_doctor_id bigint,
    p_from_date date,
    p_to_date date
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_today date :=
        (clock_timestamp() AT TIME ZONE 'Asia/Dhaka')::date;
    v_day date;
    v_schedule record;
    v_start timestamp;
    v_end timestamp;
    v_step interval;
    v_inserted integer;
    v_total integer := 0;
BEGIN
    IF p_doctor_id IS NULL
       OR p_from_date IS NULL
       OR p_to_date IS NULL THEN
        RAISE EXCEPTION 'Doctor and both dates are required';
    END IF;

    IF NOT isfinite(p_from_date)
       OR NOT isfinite(p_to_date) THEN
        RAISE EXCEPTION 'Dates must be finite';
    END IF;

    IF p_from_date < v_today THEN
        RAISE EXCEPTION 'Start date cannot be in the past';
    END IF;

    IF p_to_date < p_from_date THEN
        RAISE EXCEPTION 'End date cannot precede start date';
    END IF;

    IF p_to_date - p_from_date > 89 THEN
        RAISE EXCEPTION 'Generate at most 90 days at a time';
    END IF;

    -- Hold the doctor's account status stable during generation.
    PERFORM d.doctor_id
    FROM hospital.doctors AS d
    JOIN hospital.users AS u ON u.user_id = d.user_id
    WHERE d.doctor_id = p_doctor_id
      AND u.is_active
    FOR SHARE OF d, u;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor does not exist or is inactive';
    END IF;

    -- Lock and read the applicable weekly schedule templates.
    FOR v_schedule IN
        SELECT ds.*
        FROM hospital.doctor_schedules AS ds
        WHERE ds.doctor_id = p_doctor_id
          AND ds.is_active
          AND ds.valid_from <= p_to_date
          AND (
              ds.valid_until IS NULL
              OR ds.valid_until >= p_from_date
          )
        ORDER BY ds.schedule_id
        FOR SHARE OF ds
    LOOP
        v_step := make_interval(mins => v_schedule.slot_minutes);
        v_day := p_from_date;

        WHILE v_day <= p_to_date LOOP
            IF EXTRACT(ISODOW FROM v_day) = v_schedule.weekday
               AND v_day >= v_schedule.valid_from
               AND (
                   v_schedule.valid_until IS NULL
                   OR v_day <= v_schedule.valid_until
               ) THEN

                v_start := v_day + v_schedule.start_time;
                v_end := v_day + v_schedule.end_time;

                -- Only create full slots inside the schedule.
                WHILE v_start + v_step <= v_end LOOP
                    IF (v_start AT TIME ZONE 'Asia/Dhaka')
                       > clock_timestamp() THEN

                        INSERT INTO hospital.appointment_slots (
                            doctor_id,
                            starts_at,
                            ends_at
                        )
                        VALUES (
                            p_doctor_id,
                            v_start AT TIME ZONE 'Asia/Dhaka',
                            (v_start + v_step)
                                AT TIME ZONE 'Asia/Dhaka'
                        )
                        ON CONFLICT ON CONSTRAINT
                            no_doctor_slot_overlap
                        DO NOTHING;

                        GET DIAGNOSTICS v_inserted = ROW_COUNT;
                        v_total := v_total + v_inserted;
                    END IF;

                    v_start := v_start + v_step;
                END LOOP;
            END IF;

            v_day := v_day + 1;
        END LOOP;
    END LOOP;

    RETURN v_total;
END;
$$;

COMMIT;