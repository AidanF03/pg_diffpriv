# pg_diffpriv
A differentially private extension for PostgreSQL

## Setup

1. Install postgres by going to https://www.enterprisedb.com/downloads/postgres-postgresql-downloads and downloading the correct version
2. Start up the postgres server and ensure you can log in using the base postgres login.
3. Ensure you have xcode-select installed if on Mac
4. Install DBeaver at https://dbeaver.io/download/ (or other database access software of choice)

## Write extension

4 files will be created. A C file, a SQL file, a control file, and a Makefile

### C File

The C file will contain the function you will be implementing that needs more functionality than base SQL functionality.
It will need 
`include "postgres.h"`
`include "fmgr.h"`
`PG_MODULE_MAGIC;`
`PG_FUNCTION_INFO_V1(name of function referenced in SQL file goes here);`
to make Postgres recognize the function in the SQL file.

### SQL File

The SQL file will contain the CREATE FUNCTION that defines how the SQL database will access the C code.

### Control File

The control file will contain some metadata for the extension.

### Makefile

The Makefile will allow the extension to be created using make.

### Build extension

Once you have created these 4 files, you will run `make` and then `sudo make install` to get the code compiled to a shared libaray that Postgres can access. You can verify that the shared library was created by going to /Library/PostgreSQL/18/share/postgresql/extension and searching for your file name.

## Use extension

Before using the extension, run the privacy_budget.sql file to build the necessary implements of the privacy tracker.

After this, the extension can be tested by using the test_function.sql file on a local Postgres database. This will create a table, populate it with test data, and then try out the extension function. You should have values close to the average of the salaries returned. Adjust the sensitivity and epsilon values to get a larger or smaller spread to ensure more or less privacy.

## Troubleshooting
I am on a Mac, so these are Mac related troubleshooting issues.
You may have errors pop up due to the SDK you are using. Using `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk` worked for me to get my Makefile running without errors temporarily. 

If you get errors like `SQL Error [42883]: ERROR: could not find function "dp_laplace" in file`, then try closing and restarting DBeaver(or other database access software). This worked for me to clear it up.

You can also use the nm command line tool on the shared library created to verify that your shared library actually has the correct function name defined it it. If not, then check your C file and SQL files to ensure that the function name matches.
