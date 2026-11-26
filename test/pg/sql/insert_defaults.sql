-- INSERT defaults, column-count validation and VALUES-based CTAS.
create table t (a int, b int not null, c text default 'x');
insert into t (a,b,c) values (default, 1, default);
insert into t (b) values (2);
insert into t values (default, 3);
insert into t values (4, 5, 'y'), (default, 6, default);
select * from t order by b;
-- mismatched target list / value counts are rejected
insert into t (a,b,c) values (1,2);
insert into t (a) values (1,2);
insert into t (a,b,c) values (1,2,3,4);
select count(*) from t;
-- CTAS with a bare VALUES list
create table t2 as values (1,'a'),(2,'b');
select * from t2 order by 1;
-- INSERT ... SELECT
create table t3 (a int, b text);
insert into t3 select * from t2;
select * from t3 order by 1;
drop table t3;
drop table t2;
drop table t;
