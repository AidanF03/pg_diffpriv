-- COUNT
-- Laplacian mechanism(no delta parameter)
-- Uses truncation function without reservoir sampling
CREATE FUNCTION dp_count_laplacian_trunc(state internal, analyst_id int, user_id int, epsilon float8, k int)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_count_trans'
LANGUAGE C;

-- Gaussian mechanism(additional delta parameter)
-- Uses truncation function without reservoir sampling
CREATE FUNCTION dp_count_gaussian_trunc(state internal, analyst_id int, user_id int, epsilon float8, k int, delta float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_count_trans'
LANGUAGE C;

CREATE FUNCTION dp_count_laplacian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_count_laplacian_final'
LANGUAGE C;

CREATE FUNCTION dp_count_gaussian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_count_gaussian_final'
LANGUAGE C;

-- Use both functions together for an aggregate function
-- Laplacian mechanism(no delta parameter)
CREATE AGGREGATE dp_laplacian_count(int, int, float8, int) (
    SFUNC = dp_count_laplacian_trunc,
    STYPE = internal,
    FINALFUNC = dp_count_laplacian_final
);

-- Use both functions together for an aggregate function
-- Gaussian mechanism(additional delta parameter)
CREATE AGGREGATE dp_gaussian_count(int, int, float8, int, float8) (
    SFUNC = dp_count_gaussian_trunc,
    STYPE = internal,
    FINALFUNC = dp_count_gaussian_final
);

-- SUM
-- Truncation function that uses reservoir sampling so that different rows are randomly drawn
-- Laplacian mechanism(no delta parameter)
CREATE FUNCTION dp_sum_laplacian_trunc(state internal, analyst_id int, user_id int, value float8, epsilon float8, k int, max_value float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_sum_trans'
LANGUAGE C;

-- Truncation function that uses reservoir sampling so that different rows are randomly drawn
-- Uses truncation function without reservoir sampling
CREATE FUNCTION dp_sum_gaussian_trunc(state internal, analyst_id int, user_id int, value float8, epsilon float8, k int, max_value float8, delta float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_sum_trans'
LANGUAGE C;

CREATE FUNCTION dp_sum_laplacian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_sum_laplacian_final'
LANGUAGE C;

CREATE FUNCTION dp_sum_gaussian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_sum_gaussian_final'
LANGUAGE C;

-- Use both functions together for an aggregate function
-- Laplacian mechanism(no delta parameter)
CREATE AGGREGATE dp_laplacian_sum(int, int, float8, float8, int, float8) (
    SFUNC = dp_sum_laplacian_trunc,
    STYPE = internal,
    FINALFUNC = dp_sum_laplacian_final
);

-- Use both functions together for an aggregate function
-- Gaussian mechanism(additional delta parameter)
CREATE AGGREGATE dp_gaussian_sum(int, int, float8, float8, int, float8, float8) (
    SFUNC = dp_sum_gaussian_trunc,
    STYPE = internal,
    FINALFUNC = dp_sum_gaussian_final
);

-- AVG
-- Truncation function that uses reservoir sampling so that different rows are randomly drawn
-- Laplacian mechanism(no delta parameter)
CREATE FUNCTION dp_avg_laplacian_trans(state internal, analyst_id int, user_id int, value float8, epsilon float8, k int, max_value float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_avg_trans'
LANGUAGE C;

-- Truncation function that uses reservoir sampling so that different rows are randomly drawn
-- Uses truncation function without reservoir sampling
CREATE FUNCTION dp_avg_gaussian_trans(state internal, analyst_id int, user_id int, value float8, epsilon float8, k int, max_value float8, delta float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_avg_trans'
LANGUAGE C;

CREATE FUNCTION dp_avg_laplacian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_avg_laplacian_final'
LANGUAGE C;

CREATE FUNCTION dp_avg_gaussian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_avg_gaussian_final'
LANGUAGE C;

--Use both functions together for an aggregate function
-- Laplacian mechanism(no delta parameter)
CREATE AGGREGATE dp_laplacian_avg(int, int, float8, float8, int, float8) (
    SFUNC = dp_avg_laplacian_trans,
    STYPE = internal,
    FINALFUNC = dp_avg_laplacian_final
);

--Use both functions together for an aggregate function
-- Gaussian mechanism(additional delta parameter)
CREATE AGGREGATE dp_gaussian_avg(int, int, float8, float8, int, float8, float8) (
    SFUNC = dp_avg_gaussian_trans,
    STYPE = internal,
    FINALFUNC = dp_avg_gaussian_final
);

-- Create the schema for all the privacy tracking information
CREATE SCHEMA IF NOT EXISTS diffpriv;

-- Registered analysts with total epsilon privacy budgets.
CREATE TABLE IF NOT EXISTS diffpriv.analysts (
    analyst_id   SERIAL PRIMARY KEY,
    analyst_name VARCHAR(100) NOT NULL UNIQUE,
    total_budget NUMERIC(10,6) NOT NULL CHECK (total_budget > 0),
    budget_used  NUMERIC(10,6) NOT NULL DEFAULT 0.0 CHECK (budget_used >= 0),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT budget_not_exceeded CHECK (budget_used <= total_budget)
);

COMMENT ON TABLE diffpriv.analysts IS
    'Registered analysts with their total epsilon privacy budgets.';

-- Immutable audit log of every DP query attempt.
CREATE TABLE IF NOT EXISTS diffpriv.query_log (
    log_id        SERIAL PRIMARY KEY,
    analyst_id    INTEGER NOT NULL REFERENCES diffpriv.analysts(analyst_id),
    query_text    TEXT NOT NULL,
    epsilon_spent NUMERIC(20,6) NOT NULL CHECK (epsilon_spent >= 0),
    mechanism     VARCHAR(20) NOT NULL CHECK (mechanism IN ('laplace','gaussian')),
    sensitivity   NUMERIC(20,6) NOT NULL CHECK (sensitivity > 0),
    query_time    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    budget_before NUMERIC(10,6) NOT NULL,
    budget_after  NUMERIC(10,6) NOT NULL,
    approved      BOOLEAN NOT NULL DEFAULT TRUE,
    notes         TEXT
);

COMMENT ON TABLE diffpriv.query_log IS
    'Immutable log of all DP query requests and their epsilon spend.';

-- Used to store warnings for privacy budget exhaustion
CREATE TABLE IF NOT EXISTS diffpriv.budget_alerts (
    alert_id     SERIAL PRIMARY KEY,
    analyst_id   INTEGER NOT NULL REFERENCES diffpriv.analysts(analyst_id),
    alert_type   VARCHAR(30) NOT NULL,
    triggered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    budget_used  NUMERIC(10,6) NOT NULL,
    total_budget NUMERIC(10,6) NOT NULL
);

-- Adds a new analyst with a specified total epsilon budget.
CREATE OR REPLACE FUNCTION diffpriv.register_analyst(
    p_name   VARCHAR(100),
    p_budget NUMERIC(10,6)
)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE v_id INTEGER;
BEGIN
    IF p_budget <= 0 THEN
        RAISE EXCEPTION 'Budget must be positive. Got: %', p_budget;
    END IF;
    INSERT INTO diffpriv.analysts (analyst_name, total_budget)
    VALUES (p_name, p_budget)
    RETURNING analyst_id INTO v_id;
    RAISE NOTICE 'Analyst "%" registered with epsilon budget = %', p_name, p_budget;
    RETURN v_id;
END;
$$;

-- Returns remaining epsilon for an analyst.
CREATE OR REPLACE FUNCTION diffpriv.get_remaining_budget(p_analyst_id INTEGER)
RETURNS NUMERIC(10,6)
LANGUAGE plpgsql AS $$
DECLARE v_remaining NUMERIC(10,6);
BEGIN
    SELECT total_budget - budget_used INTO v_remaining
    FROM diffpriv.analysts
    WHERE analyst_id = p_analyst_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Analyst ID % not found or inactive.', p_analyst_id;
    END IF;
    RETURN v_remaining;
END;
$$;

-- Returns TRUE if the analyst can afford p_epsilon (dry run).
CREATE OR REPLACE FUNCTION diffpriv.check_budget(
    p_analyst_id INTEGER,
    p_epsilon    NUMERIC(10,6)
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    RETURN diffpriv.get_remaining_budget(p_analyst_id) >= p_epsilon;
END;
$$;

-- Internally used function that inserts threshold warnings into budget_alerts.
CREATE OR REPLACE FUNCTION diffpriv._raise_budget_alert(
    p_analyst_id INTEGER,
    p_used       NUMERIC(10,6),
    p_total      NUMERIC(10,6)
)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE v_pct NUMERIC(5,2);
BEGIN
    v_pct := (p_used / p_total) * 100.0;

    IF v_pct >= 100.0 THEN
        INSERT INTO diffpriv.budget_alerts(analyst_id, alert_type, budget_used, total_budget)
        VALUES (p_analyst_id, 'EXHAUSTED', p_used, p_total);
        RAISE WARNING 'Analyst % has EXHAUSTED their privacy budget (epsilon=%).', p_analyst_id, p_total;

    ELSIF v_pct >= 90.0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM diffpriv.budget_alerts
            WHERE analyst_id = p_analyst_id AND alert_type = 'WARNING_90'
              AND triggered_at > NOW() - INTERVAL '1 hour'
        ) THEN
            INSERT INTO diffpriv.budget_alerts(analyst_id, alert_type, budget_used, total_budget)
            VALUES (p_analyst_id, 'WARNING_90', p_used, p_total);
            RAISE WARNING 'Analyst % has used 90%% of their privacy budget.', p_analyst_id;
        END IF;

    ELSIF v_pct >= 75.0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM diffpriv.budget_alerts
            WHERE analyst_id = p_analyst_id AND alert_type = 'WARNING_75'
              AND triggered_at > NOW() - INTERVAL '1 hour'
        ) THEN
            INSERT INTO diffpriv.budget_alerts(analyst_id, alert_type, budget_used, total_budget)
            VALUES (p_analyst_id, 'WARNING_75', p_used, p_total);
            RAISE WARNING 'Analyst % has used 75%% of their privacy budget.', p_analyst_id;
        END IF;
    END IF;
END;
$$;

-- The main function of the privacy budget tracker.
-- Atomically deducts epsilon from analyst budget.
-- Logs the query, enforces limits, logs alerts in the table.
-- Returns the newly created budget tracker log_id on success.
-- Raises:  EXCEPTION if budget would be exceeded.
CREATE OR REPLACE FUNCTION diffpriv.spend_budget(
    p_analyst_id  INTEGER,
    p_query_text  TEXT,
    p_epsilon     NUMERIC(10,6),
    p_mechanism   VARCHAR(20),
    p_sensitivity NUMERIC(10,6),
    p_notes       TEXT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_analyst      diffpriv.analysts%ROWTYPE;
    v_remaining    NUMERIC(10,6);
    v_budget_after NUMERIC(10,6);
    v_log_id       INTEGER;
BEGIN
    -- Epsilon needs to be positive
    IF p_epsilon <= 0 THEN
        RAISE EXCEPTION 'Epsilon must be positive. Got: %', p_epsilon;
    END IF;
    -- Use one of the two mechanisms - used to log appropriate info in query log table
    IF p_mechanism NOT IN ('laplace', 'gaussian') THEN
        RAISE EXCEPTION 'Mechanism must be "laplace" or "gaussian". Got: %', p_mechanism;
    END IF;
    -- Sensitivity needs to be positive
    IF p_sensitivity <= 0 THEN
        RAISE EXCEPTION 'Sensitivity must be positive. Got: %', p_sensitivity;
    END IF;

    -- Lock row to prevent race conditions from concurrent queries
    SELECT * INTO v_analyst
    FROM diffpriv.analysts
    WHERE analyst_id = p_analyst_id AND is_active = TRUE
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Analyst ID % not found or inactive.', p_analyst_id;
    END IF;

    -- Check what the budget would be afterwards
    v_remaining    := v_analyst.total_budget - v_analyst.budget_used;
    v_budget_after := v_analyst.budget_used + p_epsilon;

    -- Enforce hard budget limit
    IF p_epsilon > v_remaining THEN
        -- Log rejected query for audit purposes
        INSERT INTO diffpriv.query_log (
            analyst_id, query_text, epsilon_spent, mechanism,
            sensitivity, budget_before, budget_after, approved, notes
        ) VALUES (
            p_analyst_id, p_query_text, p_epsilon, p_mechanism, p_sensitivity,
            v_analyst.budget_used, v_analyst.budget_used, FALSE,
            'REJECTED: insufficient budget. Requested=' || p_epsilon || ' Remaining=' || v_remaining
        ) RETURNING log_id INTO v_log_id;
        -- This is where the exception is raised for not enough budget
        RAISE EXCEPTION
            'Budget exceeded for analyst % ("%"). Requested=%, Remaining=%. Rejected (log_id=%).',
            p_analyst_id, v_analyst.analyst_name, p_epsilon, v_remaining, v_log_id;
    END IF;

    -- Deduct from budget
    UPDATE diffpriv.analysts
    SET budget_used = v_budget_after
    WHERE analyst_id = p_analyst_id;

    -- Log approved query
    INSERT INTO diffpriv.query_log (
        analyst_id, query_text, epsilon_spent, mechanism,
        sensitivity, budget_before, budget_after, approved, notes
    ) VALUES (
        p_analyst_id, p_query_text, p_epsilon, p_mechanism, p_sensitivity,
        v_analyst.budget_used, v_budget_after, TRUE, p_notes
    ) RETURNING log_id INTO v_log_id;

    -- Send out an alert
    PERFORM diffpriv._raise_budget_alert(p_analyst_id, v_budget_after, v_analyst.total_budget);

    -- Otherwise update the output console with the approved query
    RAISE NOTICE 'Approved: analyst="%", epsilon=%, remaining=%',
        v_analyst.analyst_name, p_epsilon, (v_analyst.total_budget - v_budget_after);

    RETURN v_log_id;
END;
$$;

COMMENT ON FUNCTION diffpriv.spend_budget IS
    'Atomically spend epsilon from analyst budget. Returns log_id. EXCEPTION if exceeded.';

-- This function should be used by the admin.
-- It resets analyst budget_used to 0. Useful for new time windows.
-- This is why we have budget used and total budget separately. Makes
-- it easy to reset the budget.
CREATE OR REPLACE FUNCTION diffpriv.reset_budget(
    p_analyst_id INTEGER,
    p_reason     TEXT DEFAULT 'manual reset'
)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE v_prev_used NUMERIC(10,6);
BEGIN
    SELECT budget_used INTO v_prev_used
    FROM diffpriv.analysts WHERE analyst_id = p_analyst_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Analyst ID % not found.', p_analyst_id;
    END IF;

    -- Set the budget used back down to 0
    UPDATE diffpriv.analysts SET budget_used = 0.0
    WHERE analyst_id = p_analyst_id;

    -- Log the budget reset
    INSERT INTO diffpriv.query_log (
        analyst_id, query_text, epsilon_spent, mechanism,
        sensitivity, budget_before, budget_after, approved, notes
    ) VALUES (
        p_analyst_id, '[BUDGET RESET]', 0.0, 'laplace', 1.0,
        v_prev_used, 0.0, TRUE, p_reason
    );

    RAISE NOTICE 'Budget reset for analyst_id=%. Reason: %', p_analyst_id, p_reason;
END;
$$;

-- Adjusts total_budget for an analyst.
CREATE OR REPLACE FUNCTION diffpriv.update_budget(
    p_analyst_id INTEGER,
    p_new_budget NUMERIC(10,6)
)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE v_used NUMERIC(10,6);
BEGIN
    SELECT budget_used INTO v_used
    FROM diffpriv.analysts WHERE analyst_id = p_analyst_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Analyst ID % not found.', p_analyst_id;
    END IF;
    -- If you want to lower their budget, need to reconcile that with how
    -- much budget they've already used. Probably should reset their budget first.
    IF p_new_budget < v_used THEN
        RAISE EXCEPTION 'New budget (%) < already spent (%).', p_new_budget, v_used;
    END IF;

    UPDATE diffpriv.analysts SET total_budget = p_new_budget
    WHERE analyst_id = p_analyst_id;

    RAISE NOTICE 'Budget updated for analyst_id=% -> new total=%', p_analyst_id, p_new_budget;
END;
$$;

-- View which is an overview of all analysts and their budget consumption.
CREATE OR REPLACE VIEW diffpriv.budget_status AS
SELECT
    a.analyst_id,
    a.analyst_name,
    a.total_budget,
    a.budget_used,
    ROUND(a.total_budget - a.budget_used, 6)            AS budget_remaining,
    ROUND((a.budget_used / a.total_budget) * 100.0, 2)  AS pct_used,
    a.is_active,
    COUNT(ql.log_id) FILTER (WHERE ql.approved = TRUE)  AS approved_queries,
    COUNT(ql.log_id) FILTER (WHERE ql.approved = FALSE) AS rejected_queries,
    a.created_at
FROM diffpriv.analysts a
LEFT JOIN diffpriv.query_log ql ON ql.analyst_id = a.analyst_id
GROUP BY a.analyst_id, a.analyst_name, a.total_budget,
         a.budget_used, a.is_active, a.created_at;

COMMENT ON VIEW diffpriv.budget_status IS
    'Live budget usage summary per analyst.';

-- This is a view for the full query log joined with analyst names.
CREATE OR REPLACE VIEW diffpriv.query_history AS
SELECT
    ql.log_id,
    a.analyst_name,
    ql.query_text,
    ql.mechanism,
    ql.epsilon_spent,
    ql.sensitivity,
    ql.budget_before,
    ql.budget_after,
    ql.approved,
    ql.query_time,
    ql.notes
FROM diffpriv.query_log ql
JOIN diffpriv.analysts a ON a.analyst_id = ql.analyst_id
ORDER BY ql.query_time DESC;

COMMENT ON VIEW diffpriv.query_history IS
    'Human-readable query audit log.';