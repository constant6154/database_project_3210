BEGIN;

DO $test$
DECLARE
    visit_a bigint := 0;  -- A's later booked appointment
    visit_b bigint := 0;  -- B's later booked appointment
    visit_c bigint := 0;  -- C's earlier booked appointment

    user_a integer;
    user_b integer;
    request_a bigint;
    request_b bigint;
    first_offer bigint;
    second_offer bigint;
    outcome text;
    offer_count integer;
BEGIN
    IF 0 IN (visit_a, visit_b, visit_c)
       OR visit_a = visit_b OR visit_a = visit_c OR visit_b = visit_c THEN
        RAISE EXCEPTION 'Enter three different appointment IDs at the top';
    END IF;

    SELECT p.user_id, w.request_id INTO STRICT user_a, request_a
    FROM hospital.appointments AS a
    JOIN hospital.patients AS p ON p.patient_id = a.patient_id
    JOIN hospital.waitlist_requests AS w
      ON w.original_appointment_id = a.appointment_id
    WHERE a.appointment_id = visit_a
      AND a.status = 'Booked' AND w.status = 'Active';

    SELECT p.user_id, w.request_id INTO STRICT user_b, request_b
    FROM hospital.appointments AS a
    JOIN hospital.patients AS p ON p.patient_id = a.patient_id
    JOIN hospital.waitlist_requests AS w
      ON w.original_appointment_id = a.appointment_id
    WHERE a.appointment_id = visit_b
      AND a.status = 'Booked' AND w.status = 'Active';

    IF user_a = user_b THEN
        RAISE EXCEPTION 'A and B must be different patients';
    END IF;

    -- This fires the same database trigger used by Veya's cancellation flow.
    UPDATE hospital.appointments
    SET status = 'Cancelled'
    WHERE appointment_id = visit_c AND status = 'Booked';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment % must still be Booked', visit_c;
    END IF;

    SELECT offer_id INTO first_offer
    FROM hospital.slot_offers
    WHERE released_appointment_id = visit_c
      AND request_id = request_a AND status = 'Pending';

    IF first_offer IS NULL THEN
        RAISE EXCEPTION
            'A did not receive the first offer. Check queue order, dates, doctor, conflicts and pending offers.';
    END IF;
    RAISE NOTICE 'PASS 1: A received the first offer (%)', first_offer;

    -- Only catch the expected rejection. Any other database error fails the test.
    BEGIN
        PERFORM hospital.decline_slot_offer(user_b, first_offer);
        RAISE EXCEPTION 'FAIL: B was able to decline A''s offer';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Offer unavailable for this account' THEN
            RAISE;
        END IF;
    END;
    RAISE NOTICE 'PASS 2: B cannot decline A''s offer';

    outcome := hospital.decline_slot_offer(user_a, first_offer);

    IF outcome IS DISTINCT FROM 'Declined' OR NOT EXISTS (
        SELECT 1 FROM hospital.slot_offers
        WHERE offer_id = first_offer
          AND status = 'Declined' AND resolved_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'A''s decline was not recorded correctly';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM hospital.appointments AS a
        JOIN hospital.waitlist_requests AS w
          ON w.original_appointment_id = a.appointment_id
        WHERE a.appointment_id = visit_a AND a.status = 'Booked'
          AND w.request_id = request_a AND w.status = 'Active'
    ) THEN
        RAISE EXCEPTION 'A lost the original booking or active request';
    END IF;
    RAISE NOTICE 'PASS 3: A declined, kept the booking and stayed on the waitlist';

    SELECT offer_id INTO second_offer
    FROM hospital.slot_offers
    WHERE released_appointment_id = visit_c
      AND request_id = request_b AND status = 'Pending'
      AND expires_at > clock_timestamp();

    IF second_offer IS NULL THEN
        RAISE EXCEPTION
            'B did not receive the next offer. Check B''s eligibility and queue position.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM hospital.available_slots AS s
        JOIN hospital.appointments AS a ON a.slot_id = s.slot_id
        WHERE a.appointment_id = visit_c
    ) THEN
        RAISE EXCEPTION 'The held slot is visible for ordinary booking';
    END IF;
    RAISE NOTICE 'PASS 4: B received offer (%) and the slot is held', second_offer;

    outcome := hospital.decline_slot_offer(user_a, first_offer);

    SELECT count(*) INTO offer_count
    FROM hospital.slot_offers
    WHERE released_appointment_id = visit_c;

    IF outcome IS DISTINCT FROM 'Declined' OR offer_count <> 2
       OR NOT EXISTS (
           SELECT 1 FROM hospital.slot_offers
           WHERE offer_id = second_offer AND status = 'Pending'
       ) THEN
        RAISE EXCEPTION 'Repeating A''s decline changed the handoff';
    END IF;
    RAISE NOTICE 'PASS 5: Repeating A''s decline leaves B''s offer in place';
END;
$test$;

ROLLBACK;