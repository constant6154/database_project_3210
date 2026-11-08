-- Local demonstration fixture. Run in hospital_db as postgres.
BEGIN;
DO $$
DECLARE
    b hospital.appointments%ROWTYPE;
    offer hospital.slot_offers%ROWTYPE;
    original hospital.appointments%ROWTYPE;
BEGIN
    SELECT * INTO STRICT b FROM hospital.appointments WHERE appointment_id = 34;
    IF b.status <> 'Booked' THEN RAISE EXCEPTION '#34 must still be Booked'; END IF;
    SET LOCAL ROLE hospital_app;
    IF NOT hospital.cancel_appointment(b.patient_id, b.appointment_id) THEN
        RAISE EXCEPTION 'Expected a fresh cancellation';
    END IF;
    RESET ROLE;
    SELECT * INTO STRICT offer FROM hospital.slot_offers
    WHERE released_appointment_id = b.appointment_id AND slot_id = b.slot_id
      AND status = 'Pending' AND expires_at > clock_timestamp();
    SELECT a.* INTO STRICT original FROM hospital.appointments a
    JOIN hospital.waitlist_requests w ON w.original_appointment_id = a.appointment_id
    WHERE w.request_id = offer.request_id;
    IF original.status <> 'Booked' OR original.patient_id = b.patient_id THEN
        RAISE EXCEPTION 'Recipient original booking check failed';
    END IF;
    RAISE NOTICE 'PASS: offer for request %, original appointment % remains Booked',
        offer.request_id, original.appointment_id;
    SET LOCAL ROLE hospital_app;
    IF EXISTS (SELECT 1 FROM hospital.available_slots WHERE slot_id = b.slot_id) THEN
        RAISE EXCEPTION 'Held slot still publicly listed';
    END IF;
    BEGIN
        PERFORM hospital.book_appointment(b.patient_id, b.slot_id);
        RAISE EXCEPTION 'FAIL: ordinary booking bypassed hold';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Slot is reserved for an earlier-visit offer' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'PASS: held slot hidden and ordinary booking rejected';
END;
$$;
ROLLBACK;
