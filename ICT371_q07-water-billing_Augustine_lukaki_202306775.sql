-- ICT371 Advanced Database - Mulungushi University
-- Student: Augustine lukaki (202306775)
-- Question 7: Water Meter Readings and Billing
-- PostgreSQL / PL/pgSQL

-- Tariff: first 10 units at K5 each; units above 10 at K8 each. The trigger prevents a
-- meter reading from decreasing, including direct SQL inserts/updates.

-- ============================================================
-- 7(a) Tables and seed data
-- The six readings cover zero units, exactly 10 units and more than 10 units.

CREATE TABLE customers (
 customer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 full_name VARCHAR(120) NOT NULL
);
CREATE TABLE readings (
 reading_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
 reading_month DATE NOT NULL CHECK(EXTRACT(DAY FROM reading_month)=1),
 previous_reading NUMERIC(12,2) NOT NULL CHECK(previous_reading>=0),
 current_reading NUMERIC(12,2) NOT NULL CHECK(current_reading>=0),
 UNIQUE(customer_id,reading_month)
);
CREATE TABLE bills (
 bill_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 reading_id BIGINT UNIQUE NOT NULL REFERENCES readings(reading_id),
 charge NUMERIC(12,2) NOT NULL CHECK(charge>=0),
 amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK(amount_paid>=0 AND amount_paid<=charge),
 due_on DATE NOT NULL
);
CREATE TABLE receivable_snapshot (
 snapshot_date DATE PRIMARY KEY,total_due NUMERIC(14,2) NOT NULL
);
INSERT INTO customers(full_name) VALUES ('Mwamba'),('Leya'),('Bwalya');
INSERT INTO readings(customer_id,reading_month,previous_reading,current_reading) VALUES
 (1,DATE '2026-01-01',100,100),(1,DATE '2026-02-01',100,110),
 (2,DATE '2026-01-01',200,215),(2,DATE '2026-02-01',215,220),
 (3,DATE '2026-01-01',50,55),(3,DATE '2026-02-01',55,70);

-- ============================================================
-- 7(b) Tariff function
-- Rejects NULL or negative units and returns a two-decimal amount.

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
BEGIN
 IF p_units IS NULL OR p_units<0 THEN RAISE EXCEPTION 'Units must be non-negative'; END IF;
 RETURN ROUND(LEAST(p_units,10)*5 + GREATEST(p_units-10,0)*8,2);
END; $$;

-- ============================================================
-- 7(c) Bill-generation procedure
-- Consumption is current_reading minus previous_reading. UNIQUE(reading_id) prevents a
-- second bill.

CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id BIGINT,p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_previous NUMERIC(12,2);v_current NUMERIC(12,2);v_charge NUMERIC(12,2);
BEGIN
 SELECT previous_reading,current_reading INTO v_previous,v_current
 FROM readings WHERE reading_id=p_reading_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading'; END IF;
 IF p_due_on IS NULL THEN RAISE EXCEPTION 'Due date is required'; END IF;
 IF EXISTS(SELECT 1 FROM bills WHERE reading_id=p_reading_id) THEN
  RAISE EXCEPTION 'A bill already exists for this reading';
 END IF;
 v_charge:=fn_water_charge(v_current-v_previous);
 INSERT INTO bills(reading_id,charge,amount_paid,due_on)
 VALUES(p_reading_id,v_charge,0,p_due_on);
END; $$;
CALL pr_generate_bill(1,CURRENT_DATE+14);
CALL pr_generate_bill(2,CURRENT_DATE+14);
CALL pr_generate_bill(3,CURRENT_DATE+14);
CALL pr_generate_bill(4,CURRENT_DATE+14);
CALL pr_generate_bill(5,CURRENT_DATE+14);
CALL pr_generate_bill(6,CURRENT_DATE+14);

-- ============================================================
-- 7(d) Reading-validation trigger
-- Rejects decreasing readings before they are stored.

CREATE OR REPLACE FUNCTION fn_validate_meter_reading()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.current_reading<NEW.previous_reading THEN
  RAISE EXCEPTION 'Current meter reading cannot be below previous reading';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_validate_meter_reading
BEFORE INSERT OR UPDATE ON readings FOR EACH ROW
EXECUTE FUNCTION fn_validate_meter_reading();

-- ============================================================
-- 7(e) Overdue-bills view
-- Outstanding amount is charge minus amount_paid. Fully paid bills are excluded.

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,b.due_on,(b.charge-b.amount_paid) AS outstanding_amount
FROM bills b JOIN readings r USING(reading_id)
JOIN customers c USING(customer_id)
WHERE b.due_on<CURRENT_DATE AND b.amount_paid<b.charge;

-- ============================================================
-- 7(f) Index
-- An index on due_on supports date-based overdue searches. A partial index keeps only
-- unpaid bills.

CREATE INDEX idx_unpaid_bills_due
ON bills(due_on) WHERE amount_paid<charge;
EXPLAIN SELECT bill_id,reading_id,charge-amount_paid AS outstanding
FROM bills WHERE due_on<CURRENT_DATE AND amount_paid<charge;

-- ============================================================
-- 7(g) Receivables snapshot and schedule
-- The snapshot is the total outstanding amount on bills as at the refresh run. UPSERT
-- makes reruns safe.

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO receivable_snapshot(snapshot_date,total_due)
 SELECT CURRENT_DATE,COALESCE(SUM(charge-amount_paid),0)
 FROM bills WHERE amount_paid<charge
 ON CONFLICT(snapshot_date) DO UPDATE SET total_due=EXCLUDED.total_due;
END; $$;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('daily-receivables','30 0 * * *',
 $$CALL pr_refresh_receivables()$$);
