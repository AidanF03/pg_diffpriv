-- COUNT
-- Simple truncation, as the count values are all the same for each row(just 1 per row)
CREATE FUNCTION dp_count_trunc(state internal, user_id int, epsilon float8, k int)
RETURNS internal
AS '$libdir/dp_laplace', 'dp_count_trans'
LANGUAGE C;

CREATE FUNCTION dp_count_final(state internal)
RETURNS float8
AS '$libdir/dp_laplace', 'dp_count_final'
LANGUAGE C;

--Use both functions together for an aggregate function
CREATE AGGREGATE dp_count(int, float8, int) (
    SFUNC = dp_count_trunc,
    STYPE = internal,
    FINALFUNC = dp_count_final
);

-- SUM
-- Truncation function that uses "reservoir sampling" so that different rows are randomly drawn
CREATE FUNCTION dp_sum_trunc(state internal, user_id int, value float8, epsilon float8, k int, max_value float8)
RETURNS internal
AS '$libdir/dp_laplace', 'dp_sum_trans'
LANGUAGE C;

CREATE FUNCTION dp_sum_final(state internal)
RETURNS float8
AS '$libdir/dp_laplace', 'dp_sum_final'
LANGUAGE C;

--Use both functions together for an aggregate function
CREATE AGGREGATE dp_sum(int, float8, float8, int, float8) (
    SFUNC = dp_sum_trunc,
    STYPE = internal,
    FINALFUNC = dp_sum_final
);

-- AVG
-- Truncation function that uses "reservoir sampling" so that different rows are randomly drawn

CREATE FUNCTION dp_avg_trans(state internal, user_id int, value float8, epsilon float8, k int, max_value float8)
RETURNS internal
AS '$libdir/dp_laplace', 'dp_avg_trans'
LANGUAGE C;

CREATE FUNCTION dp_avg_final(state internal)
RETURNS float8
AS '$libdir/dp_laplace', 'dp_avg_final'
LANGUAGE C;

--Use both functions together for an aggregate function
CREATE AGGREGATE dp_avg(int, float8, float8, int, float8) (
    SFUNC = dp_avg_trans,
    STYPE = internal,
    FINALFUNC = dp_avg_final
);