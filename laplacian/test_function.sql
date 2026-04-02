drop table if exists employees;

CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    name TEXT,
    department TEXT,
    salary FLOAT8,
    age INT
);

INSERT INTO employees (name, department, salary, age) VALUES
    ('Alice Johnson',  'Engineering',  95000,  34),
    ('Bob Smith',      'Engineering',  88000,  28),
    ('Carol White',    'Engineering', 102000,  41),
    ('David Brown',    'Marketing',    72000,  31),
    ('Eve Davis',      'Marketing',    68000,  26),
    ('Frank Miller',   'Marketing',    75000,  38),
    ('Grace Wilson',   'HR',           61000,  45),
    ('Henry Moore',    'HR',           58000,  33),
    ('Iris Taylor',    'HR',           63000,  29),
    ('Jack Anderson',  'Engineering', 110000,  52),
    ('Karen Thomas',   'Marketing',    71000,  36),
    ('Liam Jackson',   'Engineering',  97000,  44),
    ('Mia White',      'HR',           60000,  27),
    ('Noah Harris',    'Engineering',  89000,  31),
    ('Olivia Martin',  'Marketing',    74000,  39);


DROP EXTENSION dp_laplace;
CREATE EXTENSION dp_laplace;

SELECT 
--Parameters: userID, epsilon(privacy_budget), max number of rows allowed
dp_count(employee_id, 10.0, 3) as private_num_employees,
COUNT(*) as real_count,
--Parameters: userID, value to sum, epsilon(privacy_budget), max number of rows allowed, max value of column
dp_sum(employee_id, salary, 10.0, 3, 1000000) as private_sum_salary,
SUM(salary) as real_sum_salary,
--Parameters: userID, value to sum, epsilon(privacy_budget), max number of rows allowed, max value of column
dp_avg(employee_id, salary, 10.0, 3, 1000000) as private_avg_salary,
AVG(salary) as real_avg_salary
FROM employees;