CREATE FUNCTION dp_gaussian_noise(
    value       float8,
    sensitivity float8,
    epsilon     float8,
    delta       float8
)
RETURNS float8
AS '$libdir/dp_gaussian', 'dp_gaussian_noise'
LANGUAGE C STRICT;
