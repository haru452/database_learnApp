-- karaoke.sql のテスト。最後に "ALL KARAOKE TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../sounds.sql
\i ../vocab.sql
\i ../answer.sql
\i ../karaoke.sql
-- ほかのファイルをあとから流し直しても、karaoke の日を書ける (種類の決まりが戻らない)
\i ../schema.sql
\i ../answer.sql
\i ../sounds.sql

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
  perform public.complete_karaoke_session('Song', 'A', 'vid', 80, '[]'::jsonb);
  raise exception 'FAILED: anonymous call should fail';
exception when sqlstate '28000' then null;
end $$;

-- 2) 昨日の曲: 形の合う行だけ残り、連続記録 1、karaoke の日
select pg_temp.as_user(:'A');
select pg_temp.check((select streak from public.complete_karaoke_session('I Want It That Way', 'Backstreet Boys', 'abc123', 88, '[
  {"line":0,"text":"I want it that way","words":[{"word":"that","sound":"th"},{"word":" ","sound":"th"}]},
  {"line":"x","text":"bad line","words":[{"word":"bad","sound":"other"}]},
  {"line":3,"text":"no words","words":[]},
  "not an object"
]'::jsonb, 'Asia/Tokyo', now() - interval '1 day')) = 1, 'streak 1');
select pg_temp.check((select jsonb_array_length(items) from public.karaoke_results) = 1, 'only the valid line kept');
select pg_temp.check((select items -> 0 -> 'words' -> 0 ->> 'word' from public.karaoke_results) = 'that', 'blank word dropped');
select pg_temp.check((select count(*) from public.activity_days where kind = 'karaoke') = 1, 'one karaoke day');

-- 3) 今日 → +1。同じ日にもう一度 → 変わらない (でも保存はする)。赤い単語が無い曲も残す
select pg_temp.check((select streak from public.complete_karaoke_session('Song 2', '', '', 100, '[]'::jsonb)) = 2, 'next day -> 2');
select pg_temp.check((select already_done from public.complete_karaoke_session('Song 3', 'C', 'v3', 50, '[]'::jsonb, 'Asia/Tokyo', null,
                       'Open your mouth more on "that".')) = true, 'same day -> already done');
select pg_temp.check((select advice from public.karaoke_results where title = 'Song 3') = 'Open your mouth more on "that".', 'advice stored');
select pg_temp.check((select advice from public.karaoke_results where title = 'Song 2') = '', 'no advice -> empty');
select pg_temp.check((select count(*) from public.karaoke_results) = 3, 'all songs saved');

-- 4) ほかの練習も同じ日に書ける (種類の決まりが 7 種類のまま)
select pg_temp.check((select already_done from public.complete_short_answer_session(
  '[{"question":"Q","answers":["a"],"heard":"a","correct":true}]'::jsonb)) = true, 'answer still works');

-- 5) 苦手な音を source = karaoke で残せる
select pg_temp.check((select public.save_pronunciation_issues('Asia/Tokyo', '[{"sound":"th","weight":1,"word":"that","source":"karaoke"}]'::jsonb)) = 1, 'karaoke sound saved');
select pg_temp.check((select source from public.pronunciation_issues) = 'karaoke', 'source is karaoke');

-- 6) 曲名なし・点数が範囲外・行が 201 以上は断る
do $$
begin
  perform public.complete_karaoke_session(' ', 'A', 'v', 50, '[]'::jsonb);
  raise exception 'FAILED: empty title should fail';
exception when sqlstate '22023' then null;
end $$;
do $$
begin
  perform public.complete_karaoke_session('S', 'A', 'v', 101, '[]'::jsonb);
  raise exception 'FAILED: score 101 should fail';
exception when sqlstate '22023' then null;
end $$;
do $$
begin
  perform public.complete_karaoke_session('S', 'A', 'v', 50, (select jsonb_agg(jsonb_build_object('line', i)) from generate_series(1,201) i));
  raise exception 'FAILED: 201 lines should fail';
exception when sqlstate '22023' then null;
end $$;

-- 7) ほかの人には見えない
select pg_temp.as_user(:'B');
select pg_temp.check((select count(*) from public.karaoke_results) = 0, 'B sees nothing');
reset role;
\echo ALL KARAOKE TESTS PASSED
