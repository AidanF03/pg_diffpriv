#include "postgres.h"
#include "fmgr.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"
#include "utils/float.h"
#include <math.h>
#include "executor/spi.h"     
#include "utils/numeric.h"
#include "utils/builtins.h"
#include "catalog/pg_type.h"

// This makes sure that the module is compatible with the server
PG_MODULE_MAGIC;


/* This function will call the spend_budget SQL function to check
if the analyst actually has the budget to make the query. If not, it 
will reject them. This is how we ensure that each analyst cannot endlessly
query a value and leak the privacy that way*/
static void
spi_spend_budget(int analyst_id, char *query_desc, 
                 float8 epsilon, char *mechanism,
                 float8 sensitivity, char *note)
{
    elog(NOTICE, "spi_spend_budget called: analyst=%d eps=%f mech=%s",
         analyst_id, epsilon, mechanism);
    int ret;

    //Have to connect to the database from C to call the spend_budget function
    ret = SPI_connect();
    if (ret != SPI_OK_CONNECT)
        elog(ERROR, "dp final func: SPI_connect failed");

    //These are the types for each of the inputs to the function
    Oid argtypes[] = {INT4OID,TEXTOID,NUMERICOID,TEXTOID,NUMERICOID,TEXTOID};

    //Converts the floats to numeric type
    Datum eps_numeric  = DirectFunctionCall1(float8_numeric, Float8GetDatum(epsilon));
    Datum sens_numeric = DirectFunctionCall1(float8_numeric, Float8GetDatum(sensitivity));

    Datum values[] = {Int32GetDatum(analyst_id),
                      CStringGetTextDatum(query_desc),
                      eps_numeric,
                      CStringGetTextDatum(mechanism),
                      sens_numeric,
                      CStringGetTextDatum(note)};

    char nulls[] = "      ";

    //Actually execute the spend budget function with our given inputs
    ret = SPI_execute_with_args( "SELECT diffpriv.spend_budget($1,$2,$3,$4,$5,$6)", 6, argtypes, values, nulls, false, 0);

    if (ret != SPI_OK_SELECT)
        elog(ERROR, "dp final func: spend_budget failed with code %d", ret);

    SPI_finish();
}

//Generate gaussian(normal) noise
static double
generate_standard_normal(double sensitivity, double epsilon, double delta)
{
    double u1, u2;

    //Make sure that u1 is not 0(otherwise you get log(0) issues)
    do {
        u1 = (double)rand() / RAND_MAX;
    } while (u1 == 0.0);

    //Use random() to get a random value
    u2 = (double)random() / RAND_MAX;

    //Calculate the noise based on the sensitivity, epsilon, and delta
    double sigma  = sensitivity * sqrt(2.0 * log(1.25 / delta)) / epsilon;
    return sigma * sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

//Generate the laplacian noise
static double
generate_laplace(double sensitivity, double epsilon)
{
    //Also use random() to get a random value
    double b = sensitivity / epsilon;
    double u = (double) random() / (double) RAND_MAX - 0.5;

    //Calculate the noise based only on the sensitivity and epsilon
    return -b * copysign(1.0, u) * log(1.0 - 2.0 * fabs(u));
}

//One entry in the hash table
//Has to include seen, selected, and the reservoir array to 
//do correct reservoir sampling
typedef struct UserEntry
{
    //Assumes user_id is an integer for simplicity
    int32 user_id;     
    //Total rows seen
    int32 seen;
    //Number of rows already stored in reservoir
    int32 selected;
    //Pointer to the reservoir for this user
    double *reservoir; 
} UserEntry;

//Uses the hash table for counting the reservoir sampling, the limit 
//on number of rows for each user, and then the epsilon
//privacy parameter, max_value(for sensitivity) and delta passed in as args
typedef struct DPSumAverageState
{
    //Hash table of user entries
    HTAB *user_htab;
    //Max number of row(argument to the function)
    int32 k;
    //Analyst making the query
    int32 analyst_id;
    //Epsilon used on this query
    double epsilon;
    //Max value the attribute could have for sensitivity
    double max_value;
    //Extra delta parameter for Gaussian
    double delta;
} DPSumAverageState;

//Count only needs a simpler table, as the sampling is easy
//since all row values will be the same (each row only counts as one
//whereas in a sum or average each row could add a random amount to the total
//depending on the actual value for that row)
typedef struct DPCountState
{
    //Hash table of user entries
    HTAB *user_htab;
    //Max number of row(argument to the function)
    int32 k;
    //Analyst making the query
    int32 analyst_id;
    //Epsilon used on this query
    double epsilon;
    //Extra delta parameter for Gaussian
    double delta;
} DPCountState;

//Make the actual hash table for user entries
static HTAB *
create_htab(MemoryContext ctx)
{
    HASHCTL ctl;
    MemSet(&ctl, 0, sizeof(ctl));
    ctl.keysize = sizeof(int32);
    ctl.entrysize = sizeof(UserEntry);
    ctl.hcxt = ctx;

    //Just create an element of the hash table for the 
    return hash_create("dp user hash", 1024, &ctl,
                       HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
}

//Reservoir sampling. Essentially either adds the new
//value into the reservoir for this particular user, or randomly
//swaps out another value in the reservoir with the new one if we have
//already hit the cap on the number of values the user has in the reservoir
//(the cap is k)
static void
reservoir_update(UserEntry *entry, double value, int32 k)
{
    entry->seen++;

    //Add new value into reservoir if we haven't hit limit
    if (entry->selected < k)
    {
        entry->reservoir[entry->selected++] = value;
        return;
    }

    int j = random() % entry->seen;
    //Add in randomly if we already hit limit
    if (j < k)
    {
        entry->reservoir[j] = value;
    }
}

//Define the function for the sum first step
PG_FUNCTION_INFO_V1(dp_sum_trans);

//This part runs for every row in the table. We do 
//the things that need to happen for each row like adding it
//into the user reservoir and setting variables.
Datum
dp_sum_trans(PG_FUNCTION_ARGS)
{
    MemoryContext aggcontext;
    DPSumAverageState *state;

    if (!AggCheckCallContext(fcinfo, &aggcontext))
        elog(ERROR, "dp_sum_trans called outside aggregate context");

    //Set up the arguments for use
    if (PG_ARGISNULL(0))
    {
        state = (DPSumAverageState *) MemoryContextAllocZero(aggcontext, sizeof(DPSumAverageState));
        state->user_htab = create_htab(aggcontext);
        state->epsilon = PG_GETARG_FLOAT8(4);
        state->k = PG_GETARG_INT32(5);
        state->max_value = PG_GETARG_FLOAT8(6);
        state->analyst_id = PG_GETARG_INT32(1);

        //Check if the optional delta argument was provided
        if (PG_NARGS() > 7 && !PG_ARGISNULL(7)){
            state->delta = PG_GETARG_FLOAT8(7);
        }
        else{
            state->delta = 1;
        }
    }
    else
    {
        state = (DPSumAverageState *) PG_GETARG_POINTER(0);
    }

    if (PG_ARGISNULL(1) || PG_ARGISNULL(2))
        PG_RETURN_POINTER(state);

    //Assumer user_id is an int
    int32 user_id = PG_GETARG_INT32(2);
    double value  = PG_GETARG_FLOAT8(3);

    //Clipping values is necessary so that the noise we have to add can be bounded
    //If we did not bound it then the noise added would have to be infinite
    if (value > state->max_value) value = state->max_value;
    if (value < -state->max_value) value = -state->max_value;

    //Check if the user is in hash table already
    bool found;
    UserEntry *entry = hash_search(state->user_htab, &user_id, HASH_ENTER, &found);

    //If they are not, then initialize a reservoir for them
    if (!found)
    {
        entry->seen = 0;
        entry->selected = 0;
        entry->reservoir = MemoryContextAllocZero(aggcontext, sizeof(double) * state->k);
    }

    //Update user's reservoir
    reservoir_update(entry, value, state->k);

    PG_RETURN_POINTER(state);
}

//Register the sum function
PG_FUNCTION_INFO_V1(dp_sum_laplacian_final);

//This is the final func for the laplacian sum. This will
//check if the budget is exceeded before summing values and reject 
//the query if needed. Otherwise it returns the noised value.
Datum
dp_sum_laplacian_final(PG_FUNCTION_ARGS)
{
    DPSumAverageState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPSumAverageState *) PG_GETARG_POINTER(0);

    double total = 0.0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

    //Sensitivity depends on the max_value input and k
    double sensitivity = state->k * state->max_value;
    
    //Spend the budget
    spi_spend_budget(state->analyst_id, "sum", state->epsilon, "laplace", sensitivity, " ");

    hash_seq_init(&scan, state->user_htab);

    //Add up all values for the user in their reservoir
    while ((entry = hash_seq_search(&scan)) != NULL)
    {
        for (int i = 0; i < entry->selected; i++)
            total += entry->reservoir[i];
    }

    //Add in the noise
    double noisy = total + generate_laplace(sensitivity, state->epsilon);

    PG_RETURN_FLOAT8(noisy);
}

//Register the sum function
PG_FUNCTION_INFO_V1(dp_sum_gaussian_final);

//This is the final func for the gaussian sum. This will
//check if the budget is exceeded before summing values and reject 
//the query if needed. Otherwise it returns the noised value.
Datum
dp_sum_gaussian_final(PG_FUNCTION_ARGS)
{
    DPSumAverageState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPSumAverageState *) PG_GETARG_POINTER(0);

    double total = 0.0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

    //Sensitivity depends on the max_value input and k
    double sensitivity = state->k * state->max_value;

    spi_spend_budget(state->analyst_id, "sum", state->epsilon, "gaussian", sensitivity, "no note");

    hash_seq_init(&scan, state->user_htab);

    //Add up all values for the user in their reservoir
    while ((entry = hash_seq_search(&scan)) != NULL)
    {
        for (int i = 0; i < entry->selected; i++)
            total += entry->reservoir[i];
    }

    //Add in the noise
    double noisy = total +  generate_standard_normal(sensitivity, state->epsilon, state->delta);
    PG_RETURN_FLOAT8(noisy);
}

//Register the transition function
PG_FUNCTION_INFO_V1(dp_avg_trans);

//Average can use the same reservoir sampling for truncation
//as the sum can
Datum
dp_avg_trans(PG_FUNCTION_ARGS)
{
    return dp_sum_trans(fcinfo);
}

//Register the laplacian average function
PG_FUNCTION_INFO_V1(dp_avg_laplacian_final);

//This is the final func for the laplacian average. This will
//check if the budget is exceeded before summing values and reject 
//the query if needed. Otherwise it returns the noised value.
Datum
dp_avg_laplacian_final(PG_FUNCTION_ARGS)
{
    DPSumAverageState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPSumAverageState *) PG_GETARG_POINTER(0);

    double total = 0.0;
    int count = 0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

    //Calculate the sensitivity based on k and the max value
    double sensitivity = state->k * state->max_value;

    //Spend the budget
    spi_spend_budget(state->analyst_id, "avg", state->epsilon, "laplace", sensitivity, "no note");

    hash_seq_init(&scan, state->user_htab);

    //Add up all user values in the reservoir and keep track of count
    while ((entry = hash_seq_search(&scan)) != NULL)
    {
        for (int i = 0; i < entry->selected; i++)
        {
            total += entry->reservoir[i];
            count++;
        }
    }

    if (count == 0)
        PG_RETURN_NULL();

    //Spend half of the budget on the sum and half on the count
    //Both are needed to calculate the average
    double noisy_sum = total + generate_laplace(sensitivity, state->epsilon / 2.0);

    double noisy_count = count + generate_laplace(state->k, state->epsilon / 2.0);

    //Sum divided by count is the average
    PG_RETURN_FLOAT8(noisy_sum / noisy_count);
}

//Register the average gaussian function
PG_FUNCTION_INFO_V1(dp_avg_gaussian_final);

//This is the final func for the gaussian average. This will
//check if the budget is exceeded before summing values and reject 
//the query if needed. Otherwise it returns the noised value.
Datum
dp_avg_gaussian_final(PG_FUNCTION_ARGS)
{
    DPSumAverageState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPSumAverageState *) PG_GETARG_POINTER(0);

    double total = 0.0;
    int count = 0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

    //Calculate the sensitivity based on k and the max value
    double sensitivity = state->k * state->max_value;

    spi_spend_budget(state->analyst_id, "avg", state->epsilon, "gaussian", sensitivity, "no note");

    hash_seq_init(&scan, state->user_htab);

    //Add up all user values in the reservoir and keep track of count
    while ((entry = hash_seq_search(&scan)) != NULL)
    {
        for (int i = 0; i < entry->selected; i++)
        {
            total += entry->reservoir[i];
            count++;
        }
    }

    if (count == 0)
        PG_RETURN_NULL();

    //Spend half of the budget on the sum and half on the count
    //Both are needed to calculate the average
    //Add in the noise
    double noisy_sum = total +  generate_standard_normal(sensitivity, state->epsilon / 2.0, state->delta);

    //Add in the noise
    double noisy_count = count +  generate_standard_normal(sensitivity, state->epsilon / 2.0, state->delta);

    //Sum divided by count is the average
    PG_RETURN_FLOAT8(noisy_sum / noisy_count);
}

//Register the count transition function
PG_FUNCTION_INFO_V1(dp_count_trans);

//This is the transition function for the count queries.
//No reservoir sampling needed. Mainly just sets arguments
//and adds count up to the limit like the other functions.
Datum
dp_count_trans(PG_FUNCTION_ARGS)
{
    MemoryContext aggcontext;
    DPCountState *state;

    if (!AggCheckCallContext(fcinfo, &aggcontext))
        elog(ERROR, "dp_count_trans called outside aggregate context");

    //Get all parameters
    if (PG_ARGISNULL(0))
    {
        state = (DPCountState *) MemoryContextAllocZero(aggcontext, sizeof(DPCountState));
        state->user_htab = create_htab(aggcontext);
        state->k = PG_GETARG_INT32(4);
        state->epsilon = PG_GETARG_FLOAT8(3);
        state->analyst_id = PG_GETARG_INT32(1);

        //Check if the optional delta argument was provided
        if (PG_NARGS() > 5 && !PG_ARGISNULL(5)){
            state->delta = PG_GETARG_FLOAT8(5);
        }
        else{
            state->delta = 0;
        }
    }
    else
    {
        state = (DPCountState *) PG_GETARG_POINTER(0);
    }

    if (PG_ARGISNULL(2))
        PG_RETURN_POINTER(state);

    int32 user_id = PG_GETARG_INT32(2);

    bool found;
    UserEntry *entry = hash_search(state->user_htab, &user_id, HASH_ENTER, &found);

    //We don't need to worry about the reservoir for count
    if (!found)
    {
        entry->seen = 0;
        entry->selected = 0;
        entry->reservoir = NULL;
    }

    entry->seen++;

    //Keep adding as long as we are less than the threshold for rows(k)
    //Since the transition function runs for each row, if we've hit the limit
    //then we don't need to add in anymore. No need for a for loop or anything
    //or a reservoir because each row only counts for 1.
    if (entry->selected < state->k)
    {
        entry->selected++;
    }

    PG_RETURN_POINTER(state);
}

//Register the laplacian count function
PG_FUNCTION_INFO_V1(dp_count_laplacian_final);

//This is the final func for the laplacian count. This will
//check if the budget is exceeded before summing values and reject 
//the query if needed. Otherwise it returns the noised value.
Datum
dp_count_laplacian_final(PG_FUNCTION_ARGS)
{
    DPCountState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPCountState *) PG_GETARG_POINTER(0);

    double total = 0.0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

    //Sensitivity is just k here, each row can only 
    //contribute a max value of one to a count function
    double sensitivity = state->k;

    spi_spend_budget(state->analyst_id, "count", state->epsilon, "laplace", sensitivity, "no note");

    hash_seq_init(&scan, state->user_htab);

    //Just add up all the entries in hash table
    while ((entry = hash_seq_search(&scan)) != NULL)
    {
        total += entry->selected;
    }

    //Generate the noisy output
    double noisy = total + generate_laplace(sensitivity, state->epsilon);

    PG_RETURN_FLOAT8(noisy);
}

//Register the gaussian count
PG_FUNCTION_INFO_V1(dp_count_gaussian_final);

//This is the final func for the gaussian count. This will
//check if the budget is exceeded before summing values and reject 
//the query if needed. Otherwise it returns the noised value.
//A little easier than the other because we don't need to work
//with the reservoir as much due to all rows having the 
//same value of 1(rows only count once in a count)
Datum
dp_count_gaussian_final(PG_FUNCTION_ARGS)
{
    DPCountState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPCountState *) PG_GETARG_POINTER(0);

    double total = 0.0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

    //Sensitivity is just k here, each row can only 
    //contribute a max value of one to a count function
    double sensitivity = state->k;

    //Spend the budget
    spi_spend_budget(state->analyst_id, "count", state->epsilon, "gaussian", sensitivity, "no note");

    hash_seq_init(&scan, state->user_htab);

    //Just add up all the entries in hash table
    while ((entry = hash_seq_search(&scan)) != NULL)
    {
        total += entry->selected;
    }

    //Generate the noisy output
    double noisy = total +  generate_standard_normal(sensitivity, state->epsilon, state->delta);


    PG_RETURN_FLOAT8(noisy);
}