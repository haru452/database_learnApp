-- vocab.sql のテスト。手元の PostgreSQL で:
--   cd supabase/tests && psql -X -q -v ON_ERROR_STOP=1 -f vocab_test.sql
-- 最後に "ALL VOCAB TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../vocab.sql

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

set role authenticated;

-- 1) 未ログインは使えない
select pg_temp.as_user('');
do $$
begin
  perform public.complete_vocab_session('Asia/Tokyo');
  raise exception 'FAILED: anonymous call should fail';
exception when sqlstate '28000' then null;
end $$;

-- 2) 昨日の回 → 単語帳の日が入り、連続記録 1
select pg_temp.as_user(:'A');
select pg_temp.check((select streak from public.complete_vocab_session('Asia/Tokyo', now() - interval '1 day')) = 1,
  'first session -> streak 1');
select pg_temp.check((select count(*) from public.activity_days where kind = 'vocab') = 1, 'one vocab day');

-- 3) 今日の回 → 次の日なので +1
select pg_temp.check((select streak from public.complete_vocab_session('Asia/Tokyo', now())) = 2, 'next day -> streak 2');

-- 4) 同じ日にもう一度 → 変わらない、already_done
select pg_temp.check((select already_done from public.complete_vocab_session('Asia/Tokyo', now())) = true, 'same day -> already done');
select pg_temp.check((select streak from public.complete_vocab_session('Asia/Tokyo')) = 2, 'same day -> streak stays 2');
select pg_temp.check((select count(*) from public.activity_days where kind = 'vocab') = 2, 'same day counted once');

-- 5) カレンダーに vocab の列
select pg_temp.check((select bool_and(vocab) and not bool_or(diary) and not bool_or(repeat)
                        from public.get_my_activity_days(current_date - 10, current_date + 1)), 'activity days: vocab column');

-- 6) ほかの人には入らない
select pg_temp.as_user(:'B');
select pg_temp.check((select count(*) from public.activity_days) = 0, 'B sees no rows');
select pg_temp.check(not exists (select 1 from public.get_my_activity_days(current_date - 10, current_date + 1)), 'B has no days');

reset role;
select pg_temp.check((select count(*) from public.activity_days where user_id = :'B') = 0, 'nothing stored for B');
select pg_temp.check((select current_streak from public.streaks where user_id = :'A') = 2, 'A streak 2 in table');

-- 7) 空けてから → 1 (最後の日を 3 日前に戻して、今日の回)
update public.streaks set last_study_date = last_study_date - 3 where user_id = :'A';
delete from public.activity_days where user_id = :'A' and day >= current_date - 1;
set role authenticated;
select pg_temp.as_user(:'A');
select pg_temp.check((select streak from public.complete_vocab_session('Asia/Tokyo')) = 1, 'gap -> streak 1');
reset role;
select pg_temp.check((select best_streak from public.streaks where user_id = :'A') = 2, 'best stays 2');

-- 8) anon は呼べない
set role anon;
do $$
begin
  perform public.complete_vocab_session('Asia/Tokyo');
  raise exception 'FAILED: anon should not execute';
exception when insufficient_privilege then null;
end $$;
reset role;

-- 9) 何度実行しても壊れない (ほかの .sql を後から実行しても vocab の行で制約違反にならない)
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../vocab.sql
select pg_temp.check((select count(*) from public.activity_days where kind = 'vocab') >= 1, 'rerun keeps vocab rows');
set role authenticated;
select pg_temp.as_user(:'A');
select pg_temp.check((select bool_or(vocab) from public.get_my_activity_days(current_date - 10, current_date + 1)), 'rerun keeps vocab column');
reset role;

\echo ALL VOCAB TESTS PASSED
