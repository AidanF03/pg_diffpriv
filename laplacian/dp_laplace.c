#include "postgres.h"
#include "fmgr.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"
#include "utils/float.h"
#include <math.h>

PG_MODULE_MAGIC;

//Generate the laplacian noise
static double
generate_laplace(double sensitivity, double epsilon)
{
    double b = sensitivity / epsilon;
    double u = (double) random() / (double) RAND_MAX - 0.5;

    return -b * copysign(1.0, u) * log(1.0 - 2.0 * fabs(u));
}

//One entry in the hash table
//Has to include seen, selected, and the reservoir array to 
//do correct reservoir sampling
typedef struct UserEntry
{
    int32 user_id;
    int32 seen;        // total rows seen
    int32 selected;    // number stored in reservoir
    double *reservoir; // array of size k
} UserEntry;

//Uses the hash table for the user counts, the limit
//on number of rows for each user(k), and then the epsilon
//privacy parameter and max_value passed in as args
typedef struct DPSumState
{
    HTAB *user_htab;
    int32 k;
    double epsilon;
    double max_value;
} DPSumState;

//Count only needs a simpler table, as the sampling is easy
//since all row values will be the same (each row only counts as one
//whereas in a sum or average each row could add a random amount to the total
//depending on the actual value for that row)
typedef struct DPCountState
{
    HTAB *user_htab;
    int32 k;
    double epsilon;
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

    return hash_create("dp user hash", 1024, &ctl,
                       HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
}

//Reservoir sampling update. Essentially either adds the new
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

PG_FUNCTION_INFO_V1(dp_sum_trans);

Datum
dp_sum_trans(PG_FUNCTION_ARGS)
{
    MemoryContext aggcontext;
    DPSumState *state;

    if (!AggCheckCallContext(fcinfo, &aggcontext))
        elog(ERROR, "dp_sum_trans called outside aggregate context");

    //Set up the arguments for use
    if (PG_ARGISNULL(0))
    {
        state = (DPSumState *) MemoryContextAllocZero(aggcontext, sizeof(DPSumState));
        state->user_htab = create_htab(aggcontext);
        state->epsilon = PG_GETARG_FLOAT8(3);
        state->k = PG_GETARG_INT32(4);
        state->max_value = PG_GETARG_FLOAT8(5);
    }
    else
    {
        state = (DPSumState *) PG_GETARG_POINTER(0);
    }

    if (PG_ARGISNULL(1) || PG_ARGISNULL(2))
        PG_RETURN_POINTER(state);

    //Assumer user_id is an int
    int32 user_id = PG_GETARG_INT32(1);
    double value  = PG_GETARG_FLOAT8(2);

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

PG_FUNCTION_INFO_V1(dp_sum_final);

Datum
dp_sum_final(PG_FUNCTION_ARGS)
{
    DPSumState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPSumState *) PG_GETARG_POINTER(0);

    double total = 0.0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

    hash_seq_init(&scan, state->user_htab);

    //Add up all values for the user in their reservoir
    while ((entry = hash_seq_search(&scan)) != NULL)
    {
        for (int i = 0; i < entry->selected; i++)
            total += entry->reservoir[i];
    }

    //Sensitivity depends on the max_value input and k
    double sensitivity = state->k * state->max_value;

    //Add in the noise
    double noisy = total +
        generate_laplace(sensitivity, state->epsilon);

    PG_RETURN_FLOAT8(noisy);
}

/* =========================================================
 * dp_avg
 * ========================================================= */

PG_FUNCTION_INFO_V1(dp_avg_trans);

//Average can use the same reservoir sampling for truncation
//as the sum can
Datum
dp_avg_trans(PG_FUNCTION_ARGS)
{
    return dp_sum_trans(fcinfo);
}

PG_FUNCTION_INFO_V1(dp_avg_final);

Datum
dp_avg_final(PG_FUNCTION_ARGS)
{
    DPSumState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPSumState *) PG_GETARG_POINTER(0);

    double total = 0.0;
    int count = 0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

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

    //Calculate the sensitivity based on k and the max value
    double sensitivity = state->k * state->max_value;

    //Spend half of the budget on the sum and half on the count
    //Both are needed to calculate the average
    double noisy_sum = total +
        generate_laplace(sensitivity, state->epsilon / 2.0);

    double noisy_count = count +
        generate_laplace(state->k, state->epsilon / 2.0);

    //Sum divided by count is the average
    PG_RETURN_FLOAT8(noisy_sum / noisy_count);
}

/* =========================================================
 * dp_count
 * ========================================================= */

PG_FUNCTION_INFO_V1(dp_count_trans);

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
        state->k = PG_GETARG_INT32(3);
        state->epsilon = PG_GETARG_FLOAT8(2);
    }
    else
    {
        state = (DPCountState *) PG_GETARG_POINTER(0);
    }

    if (PG_ARGISNULL(1))
        PG_RETURN_POINTER(state);

    int32 user_id = PG_GETARG_INT32(1);

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
    if (entry->selected < state->k)
    {
        entry->selected++;
    }
    //Otherwise, add in sometimes and don't add in sometimes randomly
    else
    {
        int j = random() % entry->seen;
        if (j < state->k)
        {
            entry->selected++;
        }
    }

    PG_RETURN_POINTER(state);
}

PG_FUNCTION_INFO_V1(dp_count_final);

//Count is a little easier than the average or sum because we don't have
//to worry about how much each input could change the output
Datum
dp_count_final(PG_FUNCTION_ARGS)
{
    DPCountState *state;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();

    state = (DPCountState *) PG_GETARG_POINTER(0);

    double total = 0.0;

    HASH_SEQ_STATUS scan;
    UserEntry *entry;

    hash_seq_init(&scan, state->user_htab);

    //Just add up all the entries in hash table
    while ((entry = hash_seq_search(&scan)) != NULL)
    {
        total += entry->selected;
    }

    //Sensitivity is just k here, each row can only 
    //contribute a max value of one to a count function
    double sensitivity = state->k;

    //Generate the noisy output
    double noisy = total +
        generate_laplace(sensitivity, state->epsilon);

    PG_RETURN_FLOAT8(noisy);
}