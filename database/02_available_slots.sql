BEGIN;

CREATE OR REPLACE VIEW hospital.available_slots AS
SELECT
    s.slot_id,
    d.doctor_id,
    d.full_name AS doctor_name,
    dep.name AS department,
    d.consultation_fee,
    s.starts_at,
    s.ends_at
FROM hospital.appointment_slots AS s
JOIN hospital.doctors AS d
    ON d.doctor_id = s.doctor_id
JOIN hospital.departments AS dep
    ON dep.department_id = d.department_id
JOIN hospital.users AS u
    ON u.user_id = d.user_id
WHERE
    u.is_active = true
    AND s.is_blocked = false
    AND s.starts_at > CURRENT_TIMESTAMP
    AND NOT EXISTS (
        SELECT 1
        FROM hospital.appointments AS a
        WHERE a.slot_id = s.slot_id
          AND a.status <> 'Cancelled'
    );

COMMIT;

-- Display times in Bangladesh local time.
SET TIME ZONE 'Asia/Dhaka';

SELECT *
FROM hospital.available_slots
ORDER BY doctor_id, starts_at;