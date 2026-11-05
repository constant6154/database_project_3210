BEGIN;

DO $$
DECLARE
    v_base timestamptz;
    v_slot_id bigint;
    v_appointment_id bigint;
    v_final text;
    v_target text;
    v_offset integer := 0;
    v_rejected integer := 0;
BEGIN
    SELECT LEAST(
        COALESCE(MIN(starts_at), clock_timestamp()),
        clock_timestamp()
    ) - interval '7 days'
    INTO v_base
    FROM hospital.appointment_slots
    WHERE doctor_id = 1;

    FOREACH v_final IN ARRAY
        ARRAY['Cancelled', 'Completed', 'NoShow']
    LOOP
        INSERT INTO hospital.appointment_slots (
            doctor_id, starts_at, ends_at
        )
        VALUES (
            1,
            v_base + make_interval(hours => v_offset),
            v_base + make_interval(hours => v_offset)
                   + interval '30 minutes'
        )
        RETURNING slot_id INTO v_slot_id;

        INSERT INTO hospital.appointments (
            patient_id, slot_id, status, booked_fee, reason
        )
        VALUES (
            2, v_slot_id, 'Booked', 800, 'Status guard test'
        )
        RETURNING appointment_id INTO v_appointment_id;

        -- Direct updates deliberately test the trigger itself.
        UPDATE hospital.appointments
        SET status = v_final
        WHERE appointment_id = v_appointment_id;

        IF NOT EXISTS (
            SELECT 1
            FROM hospital.appointments
            WHERE appointment_id = v_appointment_id
              AND status = v_final
        ) THEN
            RAISE EXCEPTION 'FAIL: Booked -> % failed', v_final;
        END IF;

        RAISE NOTICE 'PASS: Booked -> % allowed', v_final;

        -- Keeping the same status must remain valid.
        UPDATE hospital.appointments
        SET status = v_final
        WHERE appointment_id = v_appointment_id;

        -- Every different status must now be rejected.
        FOREACH v_target IN ARRAY
            ARRAY['Booked', 'Cancelled', 'Completed', 'NoShow']
        LOOP
            IF v_target = v_final THEN
                CONTINUE;
            END IF;

            BEGIN
                UPDATE hospital.appointments
                SET status = v_target
                WHERE appointment_id = v_appointment_id;

                RAISE EXCEPTION 'FAIL: invalid transition accepted';
            EXCEPTION
                WHEN raise_exception THEN
                    IF SQLERRM <> format(
                        'Invalid appointment status transition: %s -> %s',
                        v_final,
                        v_target
                    ) THEN
                        RAISE;
                    END IF;

                    v_rejected := v_rejected + 1;
            END;
        END LOOP;

        RAISE NOTICE 'PASS: % cannot change to another status', v_final;
        v_offset := v_offset + 1;
    END LOOP;

    IF v_rejected <> 9 THEN
        RAISE EXCEPTION 'FAIL: expected 9 rejected transitions';
    END IF;

    RAISE NOTICE 'PASS: all 9 invalid transitions rejected';
END;
$$;

ROLLBACK;