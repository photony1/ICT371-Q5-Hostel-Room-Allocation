-- ICT371 Question 5: Hostel Room Allocation (PostgreSQL)
DROP VIEW IF EXISTS v_room_occupancy;
DROP TABLE IF EXISTS allocations, occupancy_snapshot, students, rooms CASCADE;

-- (a) Tables and constraints
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity    INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INT NOT NULL REFERENCES students(student_id),
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_alloc_status_dates CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL,
    free_beds     INT NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- (b) Function: free beds in a room
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_cap    INT;
    v_active INT;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room ID: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_cap - v_active;
END;
$$;

-- (c) Procedure: allocate room to student
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student ID: %', p_student_id;
    END IF;
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL.';
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE room allocation.', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds available.', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger: enforce capacity & one ACTIVE allocation per student on direct SQL
CREATE OR REPLACE FUNCTION fn_trg_enforce_hostel_rules()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_cap    INT;
    v_active INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF EXISTS (
            SELECT 1 FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND allocation_id IS DISTINCT FROM NEW.allocation_id
        ) THEN
            RAISE EXCEPTION 'Student % already holds an ACTIVE allocation.', NEW.student_id;
        END IF;

        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        SELECT COUNT(*) INTO v_active
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_active >= v_cap THEN
            RAISE EXCEPTION 'Room % capacity (%) exceeded.', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_enforce
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION fn_trg_enforce_hostel_rules();

-- (a) Seed data: full room (R101), partly occupied (R102), empty (R103)
INSERT INTO rooms (room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);
INSERT INTO students (student_number, full_name) VALUES
('ST01', 'Mwansa Kapambwe'), ('ST02', 'Lombe Chanda'),
('ST03', 'Mutinta Hamusonde'), ('ST04', 'Kabwe Musonda');

-- Historical ENDED allocation in R103 (leaves R103 empty)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 30, CURRENT_DATE - 5, 'ENDED');

CALL pr_allocate_room(1, 1, CURRENT_DATE - 10);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 9);  -- R101 now full (2/2)
CALL pr_allocate_room(3, 2, CURRENT_DATE - 2);  -- R102 partly occupied (1/3)

-- (e) View: room occupancy
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_number,
       r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;

-- (f) Index & EXPLAIN
-- Justification: Partial index on room_id WHERE status = 'ACTIVE' ignores historical ENDED rows,
-- making active occupancy counts per room fast and lightweight.
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN ANALYZE
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1 AND status = 'ACTIVE';

-- (g) Scheduled job: daily occupancy snapshot at 23:55
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_hostel_occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy();$$);
