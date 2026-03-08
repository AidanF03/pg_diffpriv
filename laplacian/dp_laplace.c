#include "postgres.h"
#include "fmgr.h"
#include "utils/float.h"
#include <math.h>
#include <stdlib.h>

// Postgres module
PG_MODULE_MAGIC;
// Register the function with Postgres
PG_FUNCTION_INFO_V1(laplace_noise);

// Helper function to make Laplacian noise
static double
generate_laplace(double sensitivity, double epsilon)
{
    double b = sensitivity / epsilon;
    
    double u = (double)rand() / RAND_MAX - 0.5;
    
    // This is the actual Laplacian noise calculation using the sensitivity and uniform noise
    double noise = -b * copysign(1.0, u) * log(1.0 - 2.0 * fabs(u));
    
    return noise;
}

PG_FUNCTION_INFO_V1(dp_laplace_noise);

Datum
dp_laplace_noise(PG_FUNCTION_ARGS)
{
    float8 value       = PG_GETARG_FLOAT8(0);
    float8 sensitivity = PG_GETARG_FLOAT8(1);
    float8 epsilon     = PG_GETARG_FLOAT8(2);

    // Error checking - epsilon value must be > 0
    if (epsilon <= 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("epsilon must be greater than 0")));

    // Error checking - sensitivity value must be > 0
    if (sensitivity <= 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("sensitivity must be greater than 0")));

    // The actual value is the value with the laplacian noise
    float8 result = value + generate_laplace(sensitivity, epsilon);

    PG_RETURN_FLOAT8(result);
}