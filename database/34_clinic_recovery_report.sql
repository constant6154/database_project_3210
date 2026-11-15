BEGIN;

CREATE OR REPLACE VIEW hospital.clinic_recovery_report AS
SELECT
    count(DISTINCT a.appointment_id) AS cancelled_appointments,
    count(DISTINCT o.released_appointment_id) AS cancellations_with_offers,
    count(DISTINCT o.released_appointment_id)
        FILTER (WHERE o.status = 'Accepted') AS recovered_cancellations,
    count(o.offer_id) AS total_offers,
    count(o.offer_id) FILTER (WHERE o.status = 'Pending')   AS pending_offers,
    count(o.offer_id) FILTER (WHERE o.status = 'Accepted')  AS accepted_offers,
    count(o.offer_id) FILTER (WHERE o.status = 'Declined')  AS declined_offers,
    count(o.offer_id) FILTER (WHERE o.status = 'Expired')   AS expired_offers,
    count(o.offer_id) FILTER (WHERE o.status = 'Withdrawn') AS withdrawn_offers
FROM hospital.appointments AS a
LEFT JOIN hospital.slot_offers AS o
    ON o.released_appointment_id = a.appointment_id
WHERE a.status = 'Cancelled';

COMMIT;

SELECT * FROM hospital.clinic_recovery_report;
