-- weeks.sql のテスト。手元の PostgreSQL で:
--   cd supabase/tests && psql -X -q -v ON_ERROR_STOP=1 -f weeks_test.sql
-- 最後に "ALL WEEK TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../weeks.sql

create or replace function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', what; end if;
end $$;
create or replace function pg_temp.as_user(uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid, false);
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;
grant execute on function pg_temp.as_user(text) to authenticated;

\set A '11111111-1111-1111-1111-111111111111'
\set B '22222222-2222-2222-2222-222222222222'

-- 2026-10-19 (月) 〜 10-25 (日) が「今週」。今日 = 10-23 (金)
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-10-23')) = 0, 'no days -> 0 weeks');

insert into public.activity_days (user_id, day, kind) values
  (:'A', date '2026-10-05', 'diary'),    -- 10-05〜10-11 の週 (月)
  (:'A', date '2026-10-18', 'topic'),    -- 10-12〜10-18 の週 (日曜 = 週の最後)
  (:'A', date '2026-10-13', 'repeat');   -- 同じ週にもう 1 日
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-10-23')) = 2, 'last week + the week before -> 2 (this week not yet)');
select pg_temp.check((select this_week_done from public._week_streak(:'A', date '2026-10-23')) = false, 'this week not done yet');

insert into public.activity_days (user_id, day, kind) values (:'A', date '2026-10-19', 'summary');   -- 今週の月曜
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-10-23')) = 3, 'this week done -> 3');
select pg_temp.check((select this_week_done from public._week_streak(:'A', date '2026-10-23')) = true, 'this week done');

-- 2 週空く: 今日が 11-04 (水) なら、今週 (11-02〜) も先週 (10-26〜) も無い → 0
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-11-04')) = 0, 'two empty weeks -> 0');
-- 次の週の月曜: 先週 (今週扱いだった 10-19〜) があるので続いている
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-10-26')) = 3, 'next Monday: still alive');
-- 日曜の夜 = まだ同じ週
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-10-25')) = 3, 'Sunday is the end of the week');
-- 未来の日は数えない
insert into public.activity_days (user_id, day, kind) values (:'A', date '2026-12-31', 'diary');
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-10-23')) = 3, 'future days ignored');
-- ほかの人の記録は数えない
insert into public.activity_days (user_id, day, kind) values (:'B', date '2026-10-28', 'diary');
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-10-30')) = 3, 'other users ignored');

-- 公開の関数: ログインした本人の分だけ。ログインしていなければエラー
select pg_temp.as_user(:'A');
set role authenticated;
select pg_temp.check((select count(*) from public.get_my_week_streak('Asia/Tokyo')) = 1, 'get_my_week_streak returns one row');
reset role;
select pg_temp.as_user('');
set role authenticated;
do $$ begin
  perform public.get_my_week_streak('Asia/Tokyo');
  raise exception 'FAILED: anonymous call allowed';
exception when others then
  if sqlerrm like 'FAILED%' then raise; end if;
end $$;
-- 内部の関数は直接呼べない
do $$ begin
  perform public._week_streak('11111111-1111-1111-1111-111111111111', current_date);
  raise exception 'FAILED: _week_streak callable';
exception when others then
  if sqlerrm like 'FAILED%' then raise; end if;
end $$;
reset role;

-- 何度実行しても壊れない
\i ../weeks.sql
select pg_temp.check((select weeks from public._week_streak(:'A', date '2026-10-23')) = 3, 'rerun ok');

\echo ALL WEEK TESTS PASSED
