BEGIN;

-- Keep the existing doctor IDs so their appointments
-- and schedules remain connected.
UPDATE hospital.doctors
SET full_name = 'Dr. Arif Rahman'
WHERE doctor_id = 1;

UPDATE hospital.doctors
SET full_name = 'Dr. Farhana Ahmed'
WHERE doctor_id = 2;

-- Add departments. Running this again will not duplicate them.
INSERT INTO hospital.departments (name)
VALUES
    ('Dermatology'),
    ('Neurology'),
    ('Orthopedics'),
    ('Pediatrics'),
    ('ENT'),
    ('Ophthalmology'),
    ('Gynecology')
ON CONFLICT (name) DO NOTHING;

COMMIT;

-- Check the updated doctor names.
SELECT
    d.doctor_id,
    d.full_name AS doctor_name,
    dep.name AS department
FROM hospital.doctors AS d
JOIN hospital.departments AS dep
    ON dep.department_id = d.department_id
ORDER BY d.doctor_id;

-- Check all departments.
SELECT department_id, name
FROM hospital.departments
ORDER BY name;