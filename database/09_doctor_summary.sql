SELECT
    doctor_id,
    doctor_name,
    count(*) AS total_bookings,
    count(*) FILTER (WHERE status = 'Booked') AS booked,
    count(*) FILTER (WHERE status = 'Cancelled') AS cancelled,
    count(*) FILTER (WHERE status = 'Completed') AS completed,
    COALESCE(
        sum(booked_fee) FILTER (WHERE status = 'Completed'),
        0
    ) AS completed_consultation_fees
FROM hospital.appointment_report
GROUP BY doctor_id, doctor_name
ORDER BY doctor_id;