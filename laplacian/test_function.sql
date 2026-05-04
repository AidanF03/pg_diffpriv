drop table if exists employees cascade;

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

drop table if exists orders;

CREATE TABLE orders (
    employee_id INT,
    order_num INT,
    CONSTRAINT fk_orders
        FOREIGN KEY (employee_id)
        REFERENCES employees(employee_id)
);

truncate orders;

insert into orders (employee_id, order_num) values
	(1,1),
	(1,2),
	(1,3),
	(1,4),
	(1,5),
	(2,1),
	(2,2),
	(2,3),
(3,1),(4,1),(5,1),(6,1),(7,1),(8,1),(9,1),(10,1),(11,1),(12,1),(13,1),(14,1),(15,1);

select * from employees e join orders o on e.employee_id = o.employee_id;

DELETE FROM diffpriv.budget_alerts;
DELETE FROM diffpriv.query_log;
DELETE FROM diffpriv.analysts;
ALTER SEQUENCE diffpriv.analysts_analyst_id_seq RESTART WITH 1;
ALTER SEQUENCE diffpriv.query_log_log_id_seq RESTART WITH 1;

SELECT diffpriv.register_analyst('analyst_laplace',  2.0);  -- analyst_id=1, uses Laplace
select diffpriv.update_budget(1, 1000.0);
select diffpriv.get_remaining_budget(1);
select diffpriv.reset_budget(1);
SELECT 
--Parameters: analystID, primary key column, epsilon(privacy_budget), max number of rows allowed, (delta)
dp_laplacian_count(1, e.employee_id, 10.0, 1) as private_num_employees,
COUNT(*) as real_count,
--Parameters: analystID, primary key column, value to sum, epsilon(privacy_budget), max number of rows allowed, max value of column, (delta)
dp_laplacian_sum(1, e.employee_id, salary, 100.0, 1, 1000000) as private_sum_salary,
SUM(salary) as real_sum_salary,
--Parameters: analystID, primary key column, value to sum, epsilon(privacy_budget), max number of rows allowed, max value of column, (delta)
dp_laplacian_avg(1, e.employee_id, salary, 100.0, 1, 1000000) as private_avg_salary,
AVG(salary) as real_avg_salary
FROM employees e join orders o on e.employee_id = o.employee_id;