
-- Load order:
--   1. psql -d mydb -f privacy_budget.sql
--   2. CREATE EXTENSION dp_laplace;
--   3. CREATE EXTENSION dp_gaussian;
--   4. psql -d mydb -f dp_wrappers.sql
--   5. psql -d mydb -f integrated_demo.sql
-- ============================================================

-- ============================================================
-- FUNCTION: diffpriv.dp_count
-- Differentially private COUNT with budget enforcement.
--
-- Parameters:
--   p_analyst_id  - registered analyst
--   p_table       - target table (schema-qualified if needed)
--   p_where       - optional WHERE clause, e.g. 'age > 30' (NULL = no filter)
--   p_epsilon     - privacy budget to spend
--   p_mechanism   - 'laplace' or 'gaussian'
--   p_delta       - required for gaussian only (ignored for laplace, pass 0)
--
-- Returns: noisy COUNT as float8
--
-- Usage (Laplace):
--   SELECT diffpriv.dp_count(1, 'employees', 'department=''Engineering''', 0.5, 'laplace', 0);
-- Usage (Gaussian):
--   SELECT diffpriv.dp_count(1, 'employees', NULL, 0.5, 'gaussian', 1e-5);
-- ============================================================
CREATE OR REPLACE FUNCTION diffpriv.dp_count(
    p_analyst_id INTEGER,
    p_table      TEXT,
    p_where      TEXT,
    p_epsilon    FLOAT8,
    p_mechanism  TEXT,
    p_delta      FLOAT8 DEFAULT 0.0
)
RETURNS FLOAT8
LANGUAGE plpgsql AS $$
DECLARE
    v_sql        TEXT;
    v_true_count FLOAT8;
    v_noisy      FLOAT8;
    v_query_desc TEXT;
    -- For COUNT, global sensitivity is always 1
    v_sensitivity FLOAT8 := 1.0;
BEGIN
    -- Build and run the true aggregate
    v_sql := 'SELECT COUNT(*)::float8 FROM ' || p_table;
    IF p_where IS NOT NULL AND p_where <> '' THEN
        v_sql := v_sql || ' WHERE ' || p_where;
    END IF;
    v_query_desc := v_sql;
    EXECUTE v_sql INTO v_true_count;

    -- Enforce budget BEFORE returning any result
    PERFORM diffpriv.spend_budget(
        p_analyst_id,
        v_query_desc,
        p_epsilon::NUMERIC(20,6),
        p_mechanism,
        v_sensitivity::NUMERIC(20,6),
        'dp_count wrapper'
    );

    -- Apply noise
    IF p_mechanism = 'laplace' THEN
        v_noisy := dp_laplace_noise(v_true_count, v_sensitivity, p_epsilon);
    ELSIF p_mechanism = 'gaussian' THEN
        IF p_delta <= 0.0 OR p_delta >= 1.0 THEN
            RAISE EXCEPTION 'Gaussian mechanism requires delta in (0,1). Got: %', p_delta;
        END IF;
        v_noisy := dp_gaussian_noise(v_true_count, v_sensitivity, p_epsilon, p_delta);
    ELSE
        RAISE EXCEPTION 'Unknown mechanism: %. Use "laplace" or "gaussian".', p_mechanism;
    END IF;

    -- Count must be non-negative
    RETURN GREATEST(0.0, v_noisy);
END;
$$;

COMMENT ON FUNCTION diffpriv.dp_count IS
    'Budget-enforced differentially private COUNT. Sensitivity=1 always.';

-- ============================================================
-- FUNCTION: diffpriv.dp_sum
-- Differentially private SUM with budget enforcement.
--
-- Parameters:
--   p_col_max / p_col_min - known bounds of the column (for sensitivity)
--   Sensitivity for SUM = p_col_max - p_col_min
--
-- Usage (Laplace):
--   SELECT diffpriv.dp_sum(1, 'salary', 'employees', NULL, 0, 200000, 0.5, 'laplace', 0);
-- ============================================================
CREATE OR REPLACE FUNCTION diffpriv.dp_sum(
    p_analyst_id INTEGER,
    p_column     TEXT,
    p_table      TEXT,
    p_where      TEXT,
    p_col_min    FLOAT8,
    p_col_max    FLOAT8,
    p_epsilon    FLOAT8,
    p_mechanism  TEXT,
    p_delta      FLOAT8 DEFAULT 0.0
)
RETURNS FLOAT8
LANGUAGE plpgsql AS $$
DECLARE
    v_sql         TEXT;
    v_true_sum    FLOAT8;
    v_noisy       FLOAT8;
    v_query_desc  TEXT;
    v_sensitivity FLOAT8;
BEGIN
    IF p_col_max <= p_col_min THEN
        RAISE EXCEPTION 'col_max (%) must be greater than col_min (%).', p_col_max, p_col_min;
    END IF;

    -- Sensitivity for SUM = domain range
    v_sensitivity := p_col_max - p_col_min;

    v_sql := 'SELECT COALESCE(SUM(' || p_column || '), 0)::float8 FROM ' || p_table;
    IF p_where IS NOT NULL AND p_where <> '' THEN
        v_sql := v_sql || ' WHERE ' || p_where;
    END IF;
    v_query_desc := v_sql;
    EXECUTE v_sql INTO v_true_sum;

    PERFORM diffpriv.spend_budget(
        p_analyst_id,
        v_query_desc,
        p_epsilon::NUMERIC(20,6),
        p_mechanism,
        v_sensitivity::NUMERIC(20,6),
        'dp_sum wrapper'
    );

    IF p_mechanism = 'laplace' THEN
        v_noisy := dp_laplace_noise(v_true_sum, v_sensitivity, p_epsilon);
    ELSIF p_mechanism = 'gaussian' THEN
        IF p_delta <= 0.0 OR p_delta >= 1.0 THEN
            RAISE EXCEPTION 'Gaussian mechanism requires delta in (0,1). Got: %', p_delta;
        END IF;
        v_noisy := dp_gaussian_noise(v_true_sum, v_sensitivity, p_epsilon, p_delta);
    ELSE
        RAISE EXCEPTION 'Unknown mechanism: %. Use "laplace" or "gaussian".', p_mechanism;
    END IF;

    RETURN v_noisy;
END;
$$;

COMMENT ON FUNCTION diffpriv.dp_sum IS
    'Budget-enforced differentially private SUM. Sensitivity = col_max - col_min.';

-- ============================================================
-- FUNCTION: diffpriv.dp_avg
-- Differentially private AVG with budget enforcement.
--
-- Sensitivity for AVG = (col_max - col_min) / n
-- where n is the actual row count of the query.
--
-- Usage (Gaussian):
--   SELECT diffpriv.dp_avg(1, 'salary', 'employees', 'department=''HR''',
--                          0, 200000, 0.5, 'gaussian', 1e-5);
-- ============================================================
CREATE OR REPLACE FUNCTION diffpriv.dp_avg(
    p_analyst_id INTEGER,
    p_column     TEXT,
    p_table      TEXT,
    p_where      TEXT,
    p_col_min    FLOAT8,
    p_col_max    FLOAT8,
    p_epsilon    FLOAT8,
    p_mechanism  TEXT,
    p_delta      FLOAT8 DEFAULT 0.0
)
RETURNS FLOAT8
LANGUAGE plpgsql AS $$
DECLARE
    v_sql_avg     TEXT;
    v_sql_count   TEXT;
    v_true_avg    FLOAT8;
    v_n           FLOAT8;
    v_noisy       FLOAT8;
    v_query_desc  TEXT;
    v_sensitivity FLOAT8;
BEGIN
    IF p_col_max <= p_col_min THEN
        RAISE EXCEPTION 'col_max (%) must be greater than col_min (%).', p_col_max, p_col_min;
    END IF;

    -- Get count and avg in one pass using a subquery
    v_sql_avg := 'SELECT COALESCE(AVG(' || p_column || '), 0)::float8, COUNT(*)::float8 FROM ' || p_table;
    IF p_where IS NOT NULL AND p_where <> '' THEN
        v_sql_avg := v_sql_avg || ' WHERE ' || p_where;
    END IF;
    v_query_desc := v_sql_avg;
    EXECUTE v_sql_avg INTO v_true_avg, v_n;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'No rows matched the query. Cannot compute AVG.';
    END IF;

    -- Sensitivity for AVG = (max - min) / n
    v_sensitivity := (p_col_max - p_col_min) / v_n;

    PERFORM diffpriv.spend_budget(
        p_analyst_id,
        v_query_desc,
        p_epsilon::NUMERIC(20,6),
        p_mechanism,
        v_sensitivity::NUMERIC(20,6),
        'dp_avg wrapper'
    );

    IF p_mechanism = 'laplace' THEN
        v_noisy := dp_laplace_noise(v_true_avg, v_sensitivity, p_epsilon);
    ELSIF p_mechanism = 'gaussian' THEN
        IF p_delta <= 0.0 OR p_delta >= 1.0 THEN
            RAISE EXCEPTION 'Gaussian mechanism requires delta in (0,1). Got: %', p_delta;
        END IF;
        v_noisy := dp_gaussian_noise(v_true_avg, v_sensitivity, p_epsilon, p_delta);
    ELSE
        RAISE EXCEPTION 'Unknown mechanism: %. Use "laplace" or "gaussian".', p_mechanism;
    END IF;

    RETURN v_noisy;
END;
$$;

COMMENT ON FUNCTION diffpriv.dp_avg IS
    'Budget-enforced differentially private AVG. Sensitivity = (col_max - col_min) / n.';
