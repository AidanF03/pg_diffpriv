CREATE FUNCTION dp_laplace_noise(value float8, sensitivity float8, epsilon float8)
RETURNS float8
AS '$libdir/dp_laplace', 'dp_laplace_noise'
LANGUAGE C STRICT;