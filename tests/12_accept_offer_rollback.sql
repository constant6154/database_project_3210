BEGIN ISOLATION LEVEL READ COMMITTED;

DO $$
DECLARE
    t record;
    replacement bigint;
BEGIN
    -- Find the actual offer ID using the appointment Patient B cancelled.
    SELECT
        o.offer_id,
        o.slot_id,
        w.request_id,
        a.appointment_id,
        a.patient_id,
        recipient.user_id AS recipient_user_id,
        donor.user_id AS other_user_id
    INTO t
    FROM hospital.slot_offers AS o
    JOIN hospital.waitlist_requests AS w ON w.request_id = o.request_id
    JOIN hospital.appointments AS a ON a.appointment_id = w.original_appointment_id
    JOIN hospital.patients AS recipient ON recipient.patient_id = a.patient_id
    JOIN hospital.appointments AS released
      ON released.appointment_id = o.released_appointment_id
    JOIN hospital.patients AS donor ON donor.patient_id = released.patient_id
    WHERE released.appointment_id = 39
      AND o.status = 'Pending'
      AND o.expires_at > clock_timestamp();

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No live offer from appointment 39. Use a fresh matching cancellation.';
    END IF;

    -- Check 1. Patient B tries to accept Patient A's offer.
    BEGIN
        PERFORM hospital.accept_slot_offer(t.other_user_id, t.offer_id);
        RAISE EXCEPTION 'Wrong account was allowed';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Offer unavailable for this account' THEN
            RAISE;
        END IF;
    END;

    RAISE NOTICE 'PASS 1: Patient B cannot accept this offer';

    -- Check 2. Patient A accepts. Verify all four affected records.
    replacement := hospital.accept_slot_offer(t.recipient_user_id, t.offer_id);

    IF NOT EXISTS (
        SELECT 1
        FROM hospital.appointments AS original
        JOIN hospital.appointments AS booked
          ON booked.appointment_id = replacement
        JOIN hospital.slot_offers AS o ON o.offer_id = t.offer_id
        JOIN hospital.waitlist_requests AS w ON w.request_id = o.request_id
        WHERE original.appointment_id = t.appointment_id
          AND original.status = 'Cancelled'
          AND booked.status = 'Booked'
          AND booked.patient_id = t.patient_id
          AND booked.slot_id = t.slot_id
          AND o.status = 'Accepted'
          AND o.replacement_appointment_id = replacement
          AND w.status = 'Fulfilled'
    ) THEN
        RAISE EXCEPTION 'Unexpected state after acceptance';
    END IF;

    RAISE NOTICE 'PASS 2: Visit moved, offer accepted and request fulfilled';

    -- Check 3. A repeated click must return the same appointment ID.
    IF hospital.accept_slot_offer(t.recipient_user_id, t.offer_id)
       IS DISTINCT FROM replacement THEN
        RAISE EXCEPTION 'Retry returned a different appointment';
    END IF;

    RAISE NOTICE 'PASS 3: Repeated acceptance returns the same booking';
END;
$$;

ROLLBACK;