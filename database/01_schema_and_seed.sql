-- Hospital and Doctor Appointment System | CSE 3210 | Step 2
-- Open a NEW database named hospital_db in pgAdmin Query Tool.
-- Execute this WHOLE file once. It creates nine tables in schema hospital.
-- Requires PostgreSQL 12+ and permission to install bundled btree_gist.
-- No DROP or DELETE commands. If hospital already exists, execution fails safely.
-- If any error occurs: execute ROLLBACK; before trying a corrected script.
-- Stage boundary: booking routines, authorization, audit trigger and frontend
-- are NOT implemented yet. These seed inserts are only for database learning.

BEGIN;
SET LOCAL TIME ZONE 'Asia/Dhaka';
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA hospital;
SET LOCAL search_path TO hospital, public;

CREATE TABLE users (
    user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email varchar(254) NOT NULL UNIQUE,
    password_hash text NOT NULL,
    role varchar(10) NOT NULL CHECK (role IN ('Admin','Doctor','Patient')),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT normalized_email CHECK (
        email = lower(btrim(email)) AND email LIKE '%_@_%._%'),
    CONSTRAINT user_role_pair UNIQUE (user_id, role)
);

CREATE TABLE departments (
    department_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(100) NOT NULL UNIQUE CHECK (btrim(name) <> ''),
    description text,
    location varchar(100)
);

CREATE TABLE doctors (
    doctor_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL UNIQUE,
    -- Generated constant enables a declarative role-matching foreign key.
    profile_role varchar(10) GENERATED ALWAYS AS ('Doctor'::varchar(10)) STORED,
    department_id bigint NOT NULL REFERENCES departments ON DELETE RESTRICT,
    full_name varchar(100) NOT NULL CHECK (btrim(full_name) <> ''),
    phone varchar(20),
    specialization varchar(100) NOT NULL,
    qualification varchar(150),
    experience_years integer NOT NULL DEFAULT 0 CHECK (experience_years >= 0),
    consultation_fee numeric(10,2) NOT NULL CHECK (consultation_fee >= 0),
    FOREIGN KEY (user_id, profile_role) REFERENCES users(user_id, role)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE TABLE patients (
    patient_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL UNIQUE,
    profile_role varchar(10) GENERATED ALWAYS AS ('Patient'::varchar(10)) STORED,
    full_name varchar(100) NOT NULL CHECK (btrim(full_name) <> ''),
    phone varchar(20) NOT NULL,
    date_of_birth date,
    gender varchar(10) CHECK (gender IN ('Male','Female','Other')),
    blood_group varchar(3) CHECK (blood_group IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
    address text,
    medical_history text,
    FOREIGN KEY (user_id, profile_role) REFERENCES users(user_id, role)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE TABLE doctor_schedules (
    schedule_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doctor_id bigint NOT NULL REFERENCES doctors ON DELETE RESTRICT,
    weekday smallint NOT NULL CHECK (weekday BETWEEN 1 AND 7), -- ISO: Monday=1
    start_time time NOT NULL,
    end_time time NOT NULL,
    slot_minutes integer NOT NULL DEFAULT 30 CHECK (slot_minutes BETWEEN 1 AND 1440),
    valid_from date NOT NULL,
    valid_until date,
    is_active boolean NOT NULL DEFAULT true,
    CHECK (end_time > start_time), -- overnight templates outside this project's scope
    CHECK (valid_until IS NULL OR valid_until >= valid_from),
    CHECK (extract(epoch FROM (end_time - start_time)) >= slot_minutes * 60),
    UNIQUE (doctor_id, weekday, start_time, valid_from)
);

CREATE TABLE appointment_slots (
    slot_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doctor_id bigint NOT NULL REFERENCES doctors ON DELETE RESTRICT,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    is_blocked boolean NOT NULL DEFAULT false,
    CHECK (ends_at > starts_at),
    -- [) includes start, excludes end: 09:00-09:30 and 09:30-10:00 can coexist.
    CONSTRAINT no_doctor_slot_overlap EXCLUDE USING gist (
        doctor_id WITH =,
        tstzrange(starts_at, ends_at, '[)') WITH &&
    )
);

CREATE TABLE appointments (
    appointment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id bigint NOT NULL REFERENCES patients ON DELETE RESTRICT,
    slot_id bigint NOT NULL REFERENCES appointment_slots ON DELETE RESTRICT,
    status varchar(12) NOT NULL DEFAULT 'Booked'
        CHECK (status IN ('Booked','Completed','Cancelled','NoShow')),
    reason varchar(255),
    booked_fee numeric(10,2) NOT NULL CHECK (booked_fee >= 0),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX one_occupying_appointment_per_slot
    ON appointments(slot_id) WHERE status <> 'Cancelled';
CREATE INDEX appointments_patient_history ON appointments(patient_id, created_at DESC);
CREATE INDEX slots_doctor_start ON appointment_slots(doctor_id, starts_at);
CREATE INDEX doctors_department ON doctors(department_id);

CREATE TABLE consultations (
    consultation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id bigint NOT NULL UNIQUE REFERENCES appointments ON DELETE RESTRICT,
    diagnosis text NOT NULL CHECK (btrim(diagnosis) <> ''),
    clinical_notes text,
    completed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE appointment_audit (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id bigint NOT NULL REFERENCES appointments ON DELETE RESTRICT,
    action varchar(10) NOT NULL CHECK (action IN ('INSERT','UPDATE')),
    old_values jsonb,
    new_values jsonb NOT NULL,
    changed_by bigint REFERENCES users ON DELETE RESTRICT,
    changed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX audit_appointment_time ON appointment_audit(appointment_id, changed_at);

-- FICTIONAL SAMPLE DATA. '!' is a deliberately unusable password placeholder,
-- NOT a password hash or a working login. Real hashing comes with the backend.
INSERT INTO users(email,password_hash,role) VALUES
 ('admin@example.test','!','Admin'),
 ('doctor1@example.test','!','Doctor'),
 ('doctor2@example.test','!','Doctor'),
 ('patient1@example.test','!','Patient'),
 ('patient2@example.test','!','Patient'),
 ('patient3@example.test','!','Patient');

INSERT INTO departments(name,description,location) VALUES
 ('Cardiology','Heart and cardiovascular consultations','Floor 1'),
 ('Medicine','General medical consultations','Floor 2');

INSERT INTO doctors(user_id,department_id,full_name,phone,specialization,qualification,experience_years,consultation_fee) VALUES
 (2,1,'Dr. Demo Rahman','01000000001','Cardiology','MBBS, MD',8,800),
 (3,2,'Dr. Demo Akter','01000000002','Internal Medicine','MBBS, FCPS',6,600);

INSERT INTO patients(user_id,full_name,phone,date_of_birth,gender,blood_group,address) VALUES
 (4,'Demo Patient One','01000000003','2003-05-15','Male','B+','Khulna'),
 (5,'Demo Patient Two','01000000004','2002-08-20','Female','O+','Khulna'),
 (6,'Demo Patient Three','01000000005','2001-11-10','Male','A+','Jashore');

-- Dates are relative to execution day, so the demonstration remains usable later.
INSERT INTO doctor_schedules(doctor_id,weekday,start_time,end_time,slot_minutes,valid_from)
SELECT doctor_id, extract(isodow FROM CURRENT_DATE + 1)::smallint,
       '09:00'::time,'11:00'::time,30,CURRENT_DATE
FROM doctors;

INSERT INTO appointment_slots(doctor_id,starts_at,ends_at)
SELECT d.doctor_id,
       ((CURRENT_DATE + 1 + time '09:00') + n * interval '30 minutes') AT TIME ZONE 'Asia/Dhaka',
       ((CURRENT_DATE + 1 + time '09:30') + n * interval '30 minutes') AT TIME ZONE 'Asia/Dhaka'
FROM doctors d CROSS JOIN generate_series(0,3) AS n
ORDER BY d.doctor_id,n;

INSERT INTO appointments(patient_id,slot_id,status,reason,booked_fee) VALUES
 (1,1,'Booked','Demonstration appointment',800),
 (2,2,'Cancelled','Demonstration cancellation',800),
 (3,2,'Booked','Rebooking the cancelled slot',800);

-- No invented past consultation or audit history: both tables start empty.
-- Automated rejection checks. Each expected failure is isolated in a subtransaction.
-- If a protection unexpectedly fails, an exception aborts the entire setup.
DO $$
BEGIN
    BEGIN
        INSERT INTO appointments(patient_id,slot_id,booked_fee) VALUES (2,1,800);
        RAISE EXCEPTION 'FAILED: duplicate booking was accepted';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'PASS 1: duplicate booking rejected';
    END;
    BEGIN
        INSERT INTO appointment_slots(doctor_id,starts_at,ends_at)
        SELECT doctor_id, starts_at + interval '5 minutes', ends_at
        FROM appointment_slots WHERE slot_id=1;
        RAISE EXCEPTION 'FAILED: overlapping slot was accepted';
    EXCEPTION WHEN exclusion_violation THEN
        RAISE NOTICE 'PASS 2: overlapping doctor slot rejected';
    END;
    BEGIN
        INSERT INTO appointments(patient_id,slot_id,booked_fee) VALUES (999999,3,800);
        RAISE EXCEPTION 'FAILED: missing patient was accepted';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'PASS 3: nonexistent patient rejected';
    END;
    BEGIN
        UPDATE doctors SET consultation_fee=-1 WHERE doctor_id=1;
        RAISE EXCEPTION 'FAILED: negative fee was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'PASS 4: negative fee rejected';
    END;
    BEGIN
        UPDATE users SET role='Patient' WHERE user_id=2;
        RAISE EXCEPTION 'FAILED: mismatched profile role was accepted';
    EXCEPTION WHEN foreign_key_violation OR restrict_violation THEN
        RAISE NOTICE 'PASS 5: mismatched account role rejected';
    END;
    IF (SELECT count(*) FROM appointments WHERE slot_id=2) <> 2
       OR (SELECT count(*) FROM appointments WHERE slot_id=2 AND status <> 'Cancelled') <> 1 THEN
        RAISE EXCEPTION 'FAILED: cancellation/rebooking sample invalid';
    END IF;
    RAISE NOTICE 'PASS 6: cancelled booking retained and slot rebooked';
END;
$$;

COMMIT;

-- Final result grid: expected counts below. Self-checks may leave identity gaps;
-- PostgreSQL sequences are not rolled back. Such gaps are normal.
SELECT 'users' AS table_name, count(*) AS row_count FROM hospital.users
UNION ALL SELECT 'departments',count(*) FROM hospital.departments
UNION ALL SELECT 'doctors',count(*) FROM hospital.doctors
UNION ALL SELECT 'patients',count(*) FROM hospital.patients
UNION ALL SELECT 'doctor_schedules',count(*) FROM hospital.doctor_schedules
UNION ALL SELECT 'appointment_slots',count(*) FROM hospital.appointment_slots
UNION ALL SELECT 'appointments',count(*) FROM hospital.appointments
UNION ALL SELECT 'consultations',count(*) FROM hospital.consultations
UNION ALL SELECT 'appointment_audit',count(*) FROM hospital.appointment_audit
ORDER BY table_name;

-- Run these examples separately AFTER setup if desired:
-- SELECT * FROM hospital.patients;
-- SELECT * FROM hospital.appointment_slots ORDER BY slot_id;
-- SELECT * FROM hospital.appointments ORDER BY appointment_id;
-- Stage 3 will implement active-account checks, future/blocked-slot checks,
-- patient overlap prevention, allowed status transitions, consultation completion,
-- updated_at maintenance, automatic audit logging, and restricted app permissions.
