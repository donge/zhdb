-- Set-returning functions in the target list and SQL function argument names.
select generate_series(1,3);
select generate_series(1,2), generate_series(3,5);
select generate_series(1, generate_series(1,3));
select generate_series(generate_series(1,3), generate_series(2,4));
select x, generate_series(1,2) as g from (values (10),(20)) t(x) order by x, g;
create function addn(a int, b int) returns int language sql stable as $$ select a + b $$;
select addn(2,3);
select addn(x,1) from (values (1),(2)) t(x) order by 1;
create function echo_txt(s text) returns text language sql stable as $$ select s $$;
select echo_txt('hello');
drop function echo_txt(text);
drop function addn(int,int);
