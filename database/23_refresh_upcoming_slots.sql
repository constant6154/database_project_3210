WITH clinic_day AS (
    SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dhaka')::date AS today
)
SELECT
    d.full_name AS doctor,
    hospital.generate_slots(
        d.doctor_id, c.today, c.today + 27
    ) AS new_slots
FROM hospital.doctors AS d
JOIN hospital.users AS u ON u.user_id = d.user_id
CROSS JOIN clinic_day AS c
WHERE u.is_active
ORDER BY d.doctor_id;