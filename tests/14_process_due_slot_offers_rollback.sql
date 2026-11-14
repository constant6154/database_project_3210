BEGIN;

SET LOCAL ROLE hospital_app;

DO $test$
DECLARE
    processed integer;
BEGIN
    IF current_user <> 'hospital_app' THEN
        RAISE EXCEPTION 'Test must run as hospital_app';
    END IF;

    processed := hospital.process_due_slot_offers();

    IF processed IS NULL OR processed < 0 THEN
        RAISE EXCEPTION 'Processor returned an invalid count: %', processed;
    END IF;

    RAISE NOTICE 'PASS: hospital_app processed % overdue offer(s)', processed;
END;
$test$;

ROLLBACK;
