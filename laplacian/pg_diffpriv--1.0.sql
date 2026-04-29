-- COUNT
-- Simple truncation, as the count values are all the same for each row(just 1 per row)
CREATE FUNCTION dp_count_laplacian_trunc(state internal, analyst_id int, user_id int, epsilon float8, k int)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_count_trans'
LANGUAGE C;

-- Simple truncation, as the count values are all the same for each row(just 1 per row)
CREATE FUNCTION dp_count_gaussian_trunc(state internal, analyst_id int, user_id int, epsilon float8, k int, delta float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_count_trans'
LANGUAGE C;

CREATE FUNCTION dp_count_laplacian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_count_laplacian_final'
LANGUAGE C;

CREATE FUNCTION dp_count_gaussian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_count_gaussian_final'
LANGUAGE C;

--Use both functions together for an aggregate function
CREATE AGGREGATE dp_laplacian_count(int, int, float8, int) (
    SFUNC = dp_count_laplacian_trunc,
    STYPE = internal,
    FINALFUNC = dp_count_laplacian_final
);

CREATE AGGREGATE dp_gaussian_count(int, int, float8, int, float8) (
    SFUNC = dp_count_gaussian_trunc,
    STYPE = internal,
    FINALFUNC = dp_count_gaussian_final
);
-- SUM
-- Truncation function that uses "reservoir sampling" so that different rows are randomly drawn
CREATE FUNCTION dp_sum_laplacian_trunc(state internal, analyst_id int, user_id int, value float8, epsilon float8, k int, max_value float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_sum_trans'
LANGUAGE C;

-- Truncation function that uses "reservoir sampling" so that different rows are randomly drawn
CREATE FUNCTION dp_sum_gaussian_trunc(state internal, analyst_id int, user_id int, value float8, epsilon float8, k int, max_value float8, delta float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_sum_trans'
LANGUAGE C;

CREATE FUNCTION dp_sum_laplacian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_sum_laplacian_final'
LANGUAGE C;

CREATE FUNCTION dp_sum_gaussian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_sum_gaussian_final'
LANGUAGE C;

--Use both functions together for an aggregate function
CREATE AGGREGATE dp_laplacian_sum(int, int, float8, float8, int, float8) (
    SFUNC = dp_sum_laplacian_trunc,
    STYPE = internal,
    FINALFUNC = dp_sum_laplacian_final
);

--Use both functions together for an aggregate function
CREATE AGGREGATE dp_gaussian_sum(int, int, float8, float8, int, float8, float8) (
    SFUNC = dp_sum_gaussian_trunc,
    STYPE = internal,
    FINALFUNC = dp_sum_gaussian_final
);

-- AVG
-- Truncation function that uses "reservoir sampling" so that different rows are randomly drawn

CREATE FUNCTION dp_avg_laplacian_trans(state internal, analyst_id int, user_id int, value float8, epsilon float8, k int, max_value float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_avg_trans'
LANGUAGE C;

CREATE FUNCTION dp_avg_gaussian_trans(state internal, analyst_id int, user_id int, value float8, epsilon float8, k int, max_value float8, delta float8)
RETURNS internal
AS '$libdir/pg_diffpriv', 'dp_avg_trans'
LANGUAGE C;

CREATE FUNCTION dp_avg_laplacian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_avg_laplacian_final'
LANGUAGE C;

CREATE FUNCTION dp_avg_gaussian_final(state internal)
RETURNS float8
AS '$libdir/pg_diffpriv', 'dp_avg_gaussian_final'
LANGUAGE C;

--Use both functions together for an aggregate function
CREATE AGGREGATE dp_laplacian_avg(int, int, float8, float8, int, float8) (
    SFUNC = dp_avg_laplacian_trans,
    STYPE = internal,
    FINALFUNC = dp_avg_laplacian_final
);

--Use both functions together for an aggregate function
CREATE AGGREGATE dp_gaussian_avg(int, int, float8, float8, int, float8, float8) (
    SFUNC = dp_avg_gaussian_trans,
    STYPE = internal,
    FINALFUNC = dp_avg_gaussian_final
);