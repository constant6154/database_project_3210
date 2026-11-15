BEGIN;
CREATE OR REPLACE FUNCTION hospital.staff_day(day date)
RETURNS TABLE (visit bigint, patient text, doctor text, department text, visit_time time, status text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT a.appointment_id,p.full_name::text,d.full_name::text,dep.name::text,
        (s.starts_at AT TIME ZONE 'Asia/Dhaka')::time,a.status::text
 FROM hospital.appointments a JOIN hospital.appointment_slots s USING(slot_id)
 JOIN hospital.patients p USING(patient_id) JOIN hospital.doctors d USING(doctor_id)
 JOIN hospital.departments dep USING(department_id)
 WHERE (s.starts_at AT TIME ZONE 'Asia/Dhaka')::date = day
 ORDER BY s.starts_at,d.full_name,a.appointment_id
$$;
CREATE OR REPLACE FUNCTION hospital.refresh_clinic_slots() RETURNS bigint
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT coalesce(sum(hospital.generate_slots(d.doctor_id, day, day + 27)),0)
 FROM hospital.doctors d JOIN hospital.users u USING(user_id)
 CROSS JOIN (SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dhaka')::date AS day) c
 WHERE u.is_active
$$;
ALTER FUNCTION hospital.staff_day(date) OWNER TO hospital_routine_owner;
ALTER FUNCTION hospital.refresh_clinic_slots() OWNER TO hospital_routine_owner;
REVOKE ALL ON FUNCTION hospital.staff_day(date), hospital.refresh_clinic_slots() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hospital.staff_day(date), hospital.refresh_clinic_slots() TO hospital_app;
COMMIT;
