-- Q3 Library Returns and Overdue Fines (PostgreSQL)

-- (a) Tables
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount DECIMAL(10, 2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0,
    total_fine DECIMAL(12, 2) NOT NULL DEFAULT 0.00
);

INSERT INTO books (title) VALUES
('Database System Concepts'),
('Introduction to Algorithms'),
('Operating System Concepts');

-- (b) Function
CREATE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS DECIMAL AS $$
DECLARE
    v_due DATE;
    v_returned DATE;
    v_end DATE;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_returned FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % does not exist', p_loan_id;
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));
    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
CREATE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % does not exist', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned', p_loan_id;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date is before the borrowed date';
    END IF;

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger
CREATE FUNCTION trg_loan_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loans_update
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit();

-- (a) Sample data
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
(1, 'Alice Mumba', CURRENT_DATE - 20, CURRENT_DATE - 6),   -- open and overdue
(2, 'Bob Tembo', CURRENT_DATE - 10, CURRENT_DATE + 4),     -- on time
(3, 'Chanda Lungu', CURRENT_DATE - 30, CURRENT_DATE - 16), -- returned late
(1, 'Dalitso Mwale', CURRENT_DATE - 15, CURRENT_DATE - 1), -- open and overdue
(2, 'Esther Sakala', CURRENT_DATE - 12, CURRENT_DATE - 2), -- returned on due date
(3, 'Faith Kunda', CURRENT_DATE - 3, CURRENT_DATE + 11);   -- on time

CALL pr_return_loan(3, CURRENT_DATE - 10);
CALL pr_return_loan(5, CURRENT_DATE - 2);

-- these should fail
CALL pr_return_loan(3, CURRENT_DATE);
CALL pr_return_loan(999, CURRENT_DATE);

SELECT * FROM loan_audit;

-- (e) View
CREATE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on, fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index (only unreturned loans are indexed)
CREATE INDEX idx_loans_book_open ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;

-- (g) Scheduled job
CREATE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE (returned_on IS NULL OR returned_on > p_as_of) AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_overdue', '10 0 * * *', 'CALL pr_refresh_overdue(CURRENT_DATE)');
