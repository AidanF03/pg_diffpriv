# pg_diffpriv

A differentially private extension for PostgreSQL

---

## Setup

1. Install PostgreSQL from https://www.enterprisedb.com/downloads/postgres-postgresql-downloads
2. Start the PostgreSQL server and ensure you can log in using the base postgres login
3. Ensure you have xcode-select installed if on Mac
4. Install DBeaver at https://dbeaver.io/download/ (or another database client of your choice)

---

## Writing the Extension

4 files are needed: a C file, a SQL file, a control file, and a Makefile.

### C File

The C file contains functions that require more capability than base SQL. It must include:

```c
#include "postgres.h"
#include "fmgr.h"
PG_MODULE_MAGIC;
PG_FUNCTION_INFO_V1(name_of_function);
```

### SQL File

The SQL file contains `CREATE FUNCTION` statements that define how PostgreSQL accesses the C code.

### Control File

The control file contains metadata for the extension (name, version, schema).

### Makefile

The Makefile compiles the C code into a shared library that PostgreSQL can load.

### Build the extension

Once you have created these 4 files, run:

```bash
make PG_CONFIG=/Library/PostgreSQL/17/bin/pg_config
sudo make install PG_CONFIG=/Library/PostgreSQL/17/bin/pg_config
```

You can verify the shared library was created by checking:

```
/Library/PostgreSQL/17/share/postgresql/extension/
```

---

## Install the Extension

Register the extension in your database:

```bash
psql -U postgres -d yourdb -c "CREATE EXTENSION pg_diffpriv;"
```

Load the privacy budget schema:

```bash
psql -U postgres -d yourdb -f privacy_budget.sql
```

Load test data (optional):

```bash
psql -U postgres -d yourdb -f laplacian/test_function.sql
```

This creates an `employees` table and an `orders` table for testing. You should have values close to the true aggregates returned. Adjust epsilon to get a larger or smaller spread to control the privacy level.

---

## Usage

### Register an analyst

Before making any queries, an analyst must be registered with an epsilon budget:

```sql
SELECT diffpriv.register_analyst('alice', 2.0);
```

### AVG queries

```sql
-- Laplace mechanism
SELECT dp_laplacian_avg(analyst_id, employees.employee_id, salary, epsilon, max_num_records, max_salary)
FROM employees;

-- Gaussian mechanism
SELECT dp_gaussian_avg(analyst_id, employees.employee_id, salary, epsilon, max_num_records, max_salary, delta)
FROM employees;
```

**Parameters:**

- `analyst_id` — ID of the registered analyst making the query
- `employees.employee_id` — primary key column identifying the individual whose privacy is protected
- `salary` — the attribute to aggregate
- `epsilon` — privacy parameter; higher values produce less noise
- `max_num_records` — maximum number of times any individual appears in the query result (use 1 for simple tables, higher for joins)
- `max_salary` — maximum possible value of the salary attribute (sets sensitivity)
- `delta` — (Gaussian only) probability that the privacy guarantee fails; recommended value is 1/n² where n is the number of records

### SUM queries

```sql
-- Laplace mechanism
SELECT dp_laplacian_sum(analyst_id, employees.employee_id, salary, epsilon, max_num_records, max_salary)
FROM employees;

-- Gaussian mechanism
SELECT dp_gaussian_sum(analyst_id, employees.employee_id, salary, epsilon, max_num_records, max_salary, delta)
FROM employees;
```

Parameters are identical to AVG queries.

### COUNT queries

COUNT queries do not require a column or max value parameter:

```sql
-- Laplace mechanism
SELECT dp_laplacian_count(analyst_id, employees.employee_id, epsilon, max_num_records)
FROM employees;

-- Gaussian mechanism
SELECT dp_gaussian_count(analyst_id, employees.employee_id, epsilon, max_num_records, delta)
FROM employees;
```

### Finding max_num_records for joins

When querying across joined tables, use this to find the correct value for `max_num_records`:

```sql
SELECT MAX(count)
FROM (
  SELECT COUNT(*) AS count
  FROM employees
  GROUP BY employee_id
);
```

### Finding max column value

```sql
SELECT MAX(salary) FROM employees;
```

---

## Privacy Budget Tracking

Every query atomically deducts epsilon from the analyst's budget. Queries are rejected once the budget is exhausted. Alerts are triggered at 75%, 90%, and 100% consumption.

```sql
-- Check remaining budget
SELECT diffpriv.get_remaining_budget(analyst_id);

-- View budget status for all analysts
SELECT * FROM diffpriv.budget_status;

-- View full query audit log
SELECT * FROM diffpriv.query_history;

-- Reset an analyst's budget (admin only)
SELECT diffpriv.reset_budget(analyst_id, 'reason');

-- Update an analyst's total budget (admin only)
SELECT diffpriv.update_budget(analyst_id, new_budget);
```

---

## Web UI

A Flask web UI is included in `app.py` as a demonstration of how the extension can be used in a real world application.

### Setup

```bash
pip install flask psycopg2-binary
```

Update the database password in `app.py`:

```python
DB = dict(host="localhost", dbname="yourdb", user="postgres", password="YOUR_PASSWORD", port=5432)
```

### Run

```bash
python app.py
```

Open `http://localhost:5050` in your browser.

---

## Troubleshooting

These are Mac related troubleshooting issues.

You may have errors pop up due to the SDK you are using. Using the following worked to get the Makefile running without errors:

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk
```

If you get errors like `SQL Error [42883]: ERROR: could not find function "dp_laplace" in file`, try closing and restarting DBeaver or your database client.

You can also use the `nm` command line tool on the shared library to verify that your shared library has the correct function name defined:

```bash
nm laplacian/pg_diffpriv.dylib | grep dp_
```

If the function name is not found, check your C file and SQL files to ensure the function names match.
