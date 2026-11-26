-- Basic RETURNING forms and UPDATE ... SET col = DEFAULT.
create table r (a int default 7, b text default 'x', c int);
insert into r (b) values ('one') returning *;
insert into r (b) values ('two') returning a, a + 1 as next;
insert into r (a, b) values (10, 'ten') returning r.*;
insert into r (c) values (5) returning b, c;
update r set c = 99 where b = 'one' returning *;
update r set c = default, b = 'ONE' where b = 'one' returning a, b, c;
update r set c = default where b = 'ten' returning c;
delete from r where b = 'two' returning a, b;
select * from r order by a;
drop table r;
