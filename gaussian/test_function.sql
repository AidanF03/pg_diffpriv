DROP TABLE IF EXISTS employees;

CREATE TABLE Employees (
    employee_id SERIAL PRIMARY KEY,
    name        TEXT,
    department  TEXT,
    salary      FLOAT8,
    age         INT
);

INSERT INTO Employees (name, department, salary, age) VALUES
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

CREATE EXTENSION IF NOT EXISTS dp_gaussian;

SELECT
    department,
    AVG(salary)::float8 AS real_avg,
    dp_gaussian_noise(
        AVG(salary)::float8,
        ((MAX(salary) - MIN(salary)) / COUNT(*)::float8)::float8,
        1.0::float8,
        0.00001::float8
    ) AS private_avg
FROM Employees
GROUP BY department;
