BEGIN;

CREATE TABLE hospital.waitlist_requests (
    request_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    original_appointment_id bigint NOT NULL
        REFERENCES hospital.appointments (appointment_id),

    earliest_date date NOT NULL,
    latest_date date NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    status varchar(12) NOT NULL DEFAULT 'Active'
        CHECK (status IN ('Active', 'Fulfilled', 'Withdrawn', 'Expired')),

    CHECK (earliest_date <= latest_date)
);

-- One original appointment can have only one active request at a time.
CREATE UNIQUE INDEX one_active_request_per_appointment
    ON hospital.waitlist_requests (original_appointment_id)
    WHERE status = 'Active';

-- Process active requests oldest first. The ID breaks timestamp ties.
CREATE INDEX active_waitlist_request_order
    ON hospital.waitlist_requests (requested_at, request_id)
    WHERE status = 'Active';


CREATE TABLE hospital.slot_offers (
    offer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    request_id bigint NOT NULL
        REFERENCES hospital.waitlist_requests (request_id),

    slot_id bigint NOT NULL
        REFERENCES hospital.appointment_slots (slot_id),

    -- Identifies the cancellation that made this opening available.
    released_appointment_id bigint NOT NULL
        REFERENCES hospital.appointments (appointment_id),

    offered_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamptz NOT NULL,
    resolved_at timestamptz,

    status varchar(12) NOT NULL DEFAULT 'Pending'
        CHECK (status IN (
            'Pending', 'Accepted', 'Declined', 'Expired', 'Withdrawn'
        )),

    replacement_appointment_id bigint UNIQUE
        REFERENCES hospital.appointments (appointment_id),

    CHECK (expires_at > offered_at),
    CHECK (resolved_at IS NULL OR resolved_at >= offered_at),

    -- A pending offer stays open. Every final outcome records its time.
    CHECK ((status = 'Pending') = (resolved_at IS NULL)),

    -- Only acceptance creates a replacement appointment.
    CHECK ((status = 'Accepted') = (replacement_appointment_id IS NOT NULL)),

    -- An acceptance must occur before the offer deadline.
    CHECK (status <> 'Accepted' OR resolved_at < expires_at),

    -- Don't offer the same cancellation to the same request twice.
    UNIQUE (request_id, released_appointment_id)
);

CREATE UNIQUE INDEX one_pending_offer_per_slot
    ON hospital.slot_offers (slot_id)
    WHERE status = 'Pending';

CREATE UNIQUE INDEX one_pending_offer_per_request
    ON hospital.slot_offers (request_id)
    WHERE status = 'Pending';

CREATE INDEX pending_offer_expiry
    ON hospital.slot_offers (expires_at)
    WHERE status = 'Pending';

COMMIT;