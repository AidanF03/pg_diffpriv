-- ============================================================
-- Demonstrates budget tracking + Laplace + Gaussian together
-- Run after: privacy_budget.sql, extensions loaded, dp_wrappers.sql
-- ============================================================

-- ============================================================
-- SETUP: Create Employees table (same as Aidan/Nischal's test)
-- ============================================================
DROP TABLE IF EXISTS employees CASCADE;

CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    name        TEXT,
    department  TEXT,
    salary      FLOAT8,
    age         INT
);

INSERT INTO employees (name, department, salary, age) VALUES
    ('Alice Johnson',  'Engineering',  95000, 34),
    ('Bob Smith',      'Engineering',  88000, 28),
    ('Carol White',    'Engineering', 102000, 41),
    ('David Brown',    'Marketing',    72000, 31),
    ('Eve Davis',      'Marketing',    68000, 26),
    ('Frank Miller',   'Marketing',    75000, 38),
    ('Grace Wilson',   'HR',           61000, 45),
    ('Henry Moore',    'HR',           58000, 33),
    ('Iris Taylor',    'HR',           63000, 29),
    ('Jack Anderson',  'Engineering', 110000, 52),
    ('Karen Thomas',   'Marketing',    71000, 36),
    ('Liam Jackson',   'Engineering',  97000, 44),
    ('Mia White',      'HR',           60000, 27),
    ('Noah Harris',    'Engineering',  89000, 31),
    ('Olivia Martin',  'Marketing',    74000, 39);

-- ============================================================
-- SETUP: Register analysts
-- ============================================================
-- Clean slate if re-running
DELETE FROM diffpriv.budget_alerts;
DELETE FROM diffpriv.query_log;
DELETE FROM diffpriv.analysts;
ALTER SEQUENCE diffpriv.analysts_analyst_id_seq RESTART WITH 1;
ALTER SEQUENCE diffpriv.query_log_log_id_seq RESTART WITH 1;

SELECT diffpriv.register_analyst('analyst_laplace',  2.0);  -- analyst_id=1, uses Laplace
SELECT diffpriv.register_analyst('analyst_gaussian', 2.0);  -- analyst_id=2, uses Gaussian

\echo ''
\echo '======================================================='
\echo ' INITIAL BUDGET STATUS'
\echo '======================================================='
SELECT analyst_name, total_budget, budget_used, budget_remaining
FROM diffpriv.budget_status;

-- ============================================================
-- DEMO 1: dp_count  (Laplace)
-- How many employees are in Engineering?
-- Sensitivity for COUNT is always 1.
-- ============================================================
\echo ''
\echo '--- DEMO 1: dp_count (Laplace) ---'
\echo 'True COUNT vs Private COUNT for Engineering'
SELECT
    (SELECT COUNT(*) FROM employees WHERE department = 'Engineering') AS true_count,
    diffpriv.dp_count(
        1,
        'employees',
        'department = ''Engineering''',
        0.5,        -- epsilon
        'laplace',
        0           -- delta unused for laplace
    ) AS private_count_laplace;

-- ============================================================
-- DEMO 2: dp_count  (Gaussian)
-- Same query, different mechanism.
-- ============================================================
\echo ''
\echo '--- DEMO 2: dp_count (Gaussian) ---'
SELECT
    (SELECT COUNT(*) FROM employees WHERE department = 'Engineering') AS true_count,
    diffpriv.dp_count(
        2,
        'employees',
        'department = ''Engineering''',
        0.5,        -- epsilon
        'gaussian',
        1e-5        -- delta required for gaussian
    ) AS private_count_gaussian;

-- ============================================================
-- DEMO 3: dp_sum  (Laplace)
-- Total salary bill for all employees.
-- Sensitivity = max_salary - min_salary = 200000 - 0
-- ============================================================
\echo ''
\echo '--- DEMO 3: dp_sum (Laplace) ---'
\echo 'True SUM vs Private SUM of salary'
SELECT
    (SELECT SUM(salary) FROM employees) AS true_sum,
    diffpriv.dp_sum(
        1,
        'salary',
        'employees',
        NULL,       -- no filter
        0,          -- col_min
        200000,     -- col_max
        0.5,        -- epsilon
        'laplace',
        0
    ) AS private_sum_laplace;

-- ============================================================
-- DEMO 4: dp_sum  (Gaussian)
-- ============================================================
\echo ''
\echo '--- DEMO 4: dp_sum (Gaussian) ---'
SELECT
    (SELECT SUM(salary) FROM employees) AS true_sum,
    diffpriv.dp_sum(
        2,
        'salary',
        'employees',
        NULL,
        0,
        200000,
        0.5,
        'gaussian',
        1e-5
    ) AS private_sum_gaussian;

-- ============================================================
-- DEMO 5: dp_avg  (Laplace)
-- Average salary across all departments.
-- Sensitivity = (col_max - col_min) / n
-- ============================================================
\echo ''
\echo '--- DEMO 5: dp_avg by department (Laplace) ---'
\echo 'Matches Aidan''s original test_function.sql pattern'
SELECT
    department,
    ROUND(AVG(salary)::NUMERIC, 2) AS true_avg,
    ROUND(
        diffpriv.dp_avg(
            1,
            'salary',
            'employees',
            'department = ''' || department || '''',
            0,
            200000,
            0.3,       -- epsilon per department query
            'laplace',
            0
        )::NUMERIC, 2
    ) AS private_avg_laplace
FROM employees
GROUP BY department
ORDER BY department;

-- ============================================================
-- DEMO 6: dp_avg  (Gaussian)
-- Matches Nischal's original test_function.sql pattern
-- ============================================================
\echo ''
\echo '--- DEMO 6: dp_avg by department (Gaussian) ---'
SELECT
    department,
    ROUND(AVG(salary)::NUMERIC, 2) AS true_avg,
    ROUND(
        diffpriv.dp_avg(
            2,
            'salary',
            'employees',
            'department = ''' || department || '''',
            0,
            200000,
            0.3,
            'gaussian',
            1e-5
        )::NUMERIC, 2
    ) AS private_avg_gaussian
FROM employees
GROUP BY department
ORDER BY department;

-- ============================================================
-- DEMO 7: Budget rejection
-- analyst_laplace spent 0.5+0.5+0.5+(0.3*3)=2.4 > 2.0 budget
-- The 3 department AVG queries above cost 0.3*3=0.9
-- Total so far: 0.5+0.5+0.9 = 1.9 of 2.0
-- This next query asks for 0.5 but only 0.1 remains -> REJECTED
-- ============================================================
\echo ''
\echo '--- DEMO 7: Budget exhaustion (expect rejection) ---'
DO $$
BEGIN
    PERFORM diffpriv.dp_avg(
        1, 'age', 'employees', NULL,
        18, 70,   -- age bounds
        0.5,      -- epsilon - more than remaining budget
        'laplace', 0
    );
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '[EXPECTED REJECTION] %', SQLERRM;
END;
$$;

-- ============================================================
-- FINAL: Budget status and full audit log
-- ============================================================
\echo ''
\echo '======================================================='
\echo ' FINAL BUDGET STATUS'
\echo '======================================================='
SELECT
    analyst_name,
    total_budget,
    budget_used,
    budget_remaining,
    pct_used,
    approved_queries,
    rejected_queries
FROM diffpriv.budget_status;

\echo ''
\echo '======================================================='
\echo ' FULL QUERY AUDIT LOG'
\echo '======================================================='
SELECT
    log_id,
    analyst_name,
    mechanism,
    ROUND(epsilon_spent::NUMERIC, 4)  AS epsilon,
    ROUND(sensitivity::NUMERIC, 4)    AS sensitivity,
    ROUND(budget_before::NUMERIC, 4)  AS before,
    ROUND(budget_after::NUMERIC, 4)   AS after,
    approved,
    LEFT(query_text, 60)              AS query_preview
FROM diffpriv.query_history;

\echo ''
\echo '======================================================='
\echo ' BUDGET ALERTS'
\echo '======================================================='
SELECT
    a.analyst_name,
    ba.alert_type,
    ROUND((ba.budget_used / ba.total_budget * 100)::NUMERIC, 1) AS pct_at_trigger,
    ba.triggered_at
FROM diffpriv.budget_alerts ba
JOIN diffpriv.analysts a ON a.analyst_id = ba.analyst_id
ORDER BY ba.triggered_at;
