-- answer.sql のテスト。最後に "ALL ANSWER TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../vocab.sql
\i ../answer.sql
-- ほかのファイルをあとから流し直しても、answer と vocab の日を書ける (種類の決まりが戻らない)
\i ../schema.sql
\i ../repeat.sql
\i ../topic.sql

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
  perform public.complete_short_answer_session('[]'::jsonb);
  raise exception 'FAILED: anonymous call should fail';
exception when sqlstate '28000' then null;
end $$;

-- 2) 昨日の回: 正しい問題だけ残り、連続記録 1、answer の日
select pg_temp.as_user(:'A');
select pg_temp.check((select saved from public.complete_short_answer_session('[
  {"question":"What do you use to open a door?","answers":["key","keys"," "],"heard":"a key","correct":true},
  {"question":"What do you drink when you are thirsty?","answers":["water"],"heard":"juice","correct":false},
  {"question":"","answers":["x"],"correct":true},
  {"question":"No answers?","answers":[],"correct":true},
  {"question":"Missing correct","answers":["y"]}
]'::jsonb, 'Asia/Tokyo', now() - interval '1 day')) = 2, 'two questions saved');
select pg_temp.check((select current_streak from public.streaks where user_id = :'A') = 1, 'streak 1');
select pg_temp.check((select count(*) from public.activity_days where kind = 'answer') = 1, 'one answer day');
select pg_temp.check((select answers from public.short_answer_results where correct) = array['key','keys'], 'blank answers dropped');

-- 3) 今日 → +1。同じ日にもう一度 → 変わらない
select pg_temp.check((select streak from public.complete_short_answer_session(
  '[{"question":"Q","answers":["a"],"heard":"a","correct":true}]'::jsonb)) = 2, 'next day -> 2');
select pg_temp.check((select already_done from public.complete_short_answer_session(
  '[{"question":"Q2","answers":["a"],"heard":"b","correct":false}]'::jsonb)) = true, 'same day -> already done');
select pg_temp.check((select count(*) from public.short_answer_results) = 4, 'all sessions saved');

-- 4) 単語帳も同じ日に書ける (種類の決まりが 6 種類のまま)
select pg_temp.check((select streak from public.complete_vocab_session('Asia/Tokyo')) = 2, 'vocab still works after re-running files');

-- 5) 1 問も正しくない・21 問以上は断る
do $$
begin
  perform public.complete_short_answer_session('[{"question":"","answers":["a"],"correct":true}]'::jsonb);
  raise exception 'FAILED: no valid items should fail';
exception when sqlstate '22023' then null;
end $$;
do $$
begin
  perform public.complete_short_answer_session((select jsonb_agg(jsonb_build_object('question','q'||i,'answers',jsonb_build_array('a'),'correct',true)) from generate_series(1,21) i));
  raise exception 'FAILED: 21 items should fail';
exception when sqlstate '22023' then null;
end $$;

-- 6) ほかの人には見えない
select pg_temp.as_user(:'B');
select pg_temp.check((select count(*) from public.short_answer_results) = 0, 'B sees nothing');
reset role;

-- 7) anon は呼べない
set role anon;
do $$
begin
  perform public.complete_short_answer_session('[]'::jsonb);
  raise exception 'FAILED: anon should not execute';
exception when insufficient_privilege then null;
end $$;
reset role;

\echo ALL ANSWER TESTS PASSED
