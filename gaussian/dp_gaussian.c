#include "postgres.h"
#include "fmgr.h"
#include "utils/float.h"
#include <math.h>
#include <stdlib.h>

PG_MODULE_MAGIC;

/*
 * Box-Muller transform to generate a standard normal sample.
 * Returns a value drawn from N(0, 1).
 */
static double
generate_standard_normal(void)
{
    double u1, u2;

    /* Avoid log(0) by ensuring u1 is never zero */
    do {
        u1 = (double)rand() / RAND_MAX;
    } while (u1 == 0.0);

    u2 = (double)rand() / RAND_MAX;

    return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

/*
 * Gaussian mechanism for differential privacy.
 *
 * Adds noise drawn from N(0, sigma^2) where:
 *   sigma = sensitivity * sqrt(2 * ln(1.25 / delta)) / epsilon
 *
 * Parameters:
 *   value       - the true aggregate result
 *   sensitivity - the global sensitivity of the query (e.g. max - min for AVG)
 *   epsilon     - privacy budget parameter (> 0, typically <= 1)
 *   delta       - relaxation parameter (> 0 and < 1, typically 1e-5)
 *
 * This satisfies (epsilon, delta)-differential privacy.
 */
PG_FUNCTION_INFO_V1(dp_gaussian_noise);

Datum
dp_gaussian_noise(PG_FUNCTION_ARGS)
{
    float8 value       = PG_GETARG_FLOAT8(0);
    float8 sensitivity = PG_GETARG_FLOAT8(1);
    float8 epsilon     = PG_GETARG_FLOAT8(2);
    float8 delta       = PG_GETARG_FLOAT8(3);

    if (epsilon <= 0.0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("epsilon must be greater than 0")));

    if (sensitivity <= 0.0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("sensitivity must be greater than 0")));

    if (delta <= 0.0 || delta >= 1.0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("delta must be in the range (0, 1)")));

    double sigma  = sensitivity * sqrt(2.0 * log(1.25 / delta)) / epsilon;
    float8 result = value + sigma * generate_standard_normal();

    PG_RETURN_FLOAT8(result);
}