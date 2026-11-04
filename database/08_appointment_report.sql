BEGIN;

CREATE OR REPLACE VIEW hospital.appointment_report AS
SELECT
    a.appointment_id,
    p.patient_id,
    p.full_name AS patient_name,
    d.doctor_id,
    d.full_name AS doctor_name,
    dep.name AS department,
    s.slot_id,
    s.starts_at,
    s.ends_at,
    a.status,
    a.reason,
    a.booked_fee,
    c.diagnosis,
    c.clinical_notes,
    c.completed_at,
    a.created_at,
    a.updated_at
FROM hospital.appointments AS a
JOIN hospital.patients AS p
    ON p.patient_id = a.patient_id
JOIN hospital.appointment_slots AS s
    ON s.slot_id = a.slot_id
JOIN hospital.doctors AS d
    ON d.doctor_id = s.doctor_id
JOIN hospital.departments AS dep
    ON dep.department_id = d.department_id
LEFT JOIN hospital.consultations AS c
    ON c.appointment_id = a.appointment_id;

COMMIT;

SET TIME ZONE 'Asia/Dhaka';

SELECT
    appointment_id,
    patient_name,
    doctor_name,
    department,
    starts_at,
    status,
    booked_fee,
    diagnosis
FROM hospital.appointment_report
ORDER BY starts_at, appointment_id;