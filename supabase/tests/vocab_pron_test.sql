-- vocab_pron.sql のテスト。最後に "ALL VOCAB PRON TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../vocab.sql
\i ../vocab_pron.sql

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
  perform public.save_vocab_pron_logs('[]'::jsonb);
  raise exception 'FAILED: anonymous call should fail';
exception when sqlstate '28000' then null;
end $$;

-- 2) 苦手な音のある語だけ残る。知らない音・知らない判定・空の語は捨てる。音は 2 つまで、重ならない
select pg_temp.as_user(:'A');
select pg_temp.check(public.save_vocab_pron_logs('[
  {"word":" Think ","rating":"close","sounds":["th"],"advice":"舌を歯の間に","heard":"sink"},
  {"word":"right","rating":"practice","sounds":["r_l","r_l","stress","vowel"]},
  {"word":"apple","rating":"good","sounds":[]},
  {"word":"very","rating":"close","sounds":["zzz"]},
  {"word":"","rating":"close","sounds":["th"]},
  {"word":"lot","rating":"great","sounds":["r_l"]},
  "not an object"
]'::jsonb) = 2, 'two words kept');
select pg_temp.check((select word from public.vocab_pron_logs where sounds @> array['th']) = 'think', 'word trimmed and lowered');
select pg_temp.check((select heard from public.vocab_pron_logs where word = 'think') = 'sink', 'heard kept');
select pg_temp.check((select cardinality(sounds) from public.vocab_pron_logs where word = 'right') = 2, 'at most 2 sounds, no repeats');

-- 3) まとめない: 同じ語をもう一度 → 2 行になる
select pg_temp.check(public.save_vocab_pron_logs('[{"word":"think","rating":"close","sounds":["th"]}]'::jsonb) = 1, 'same word saved again');
select pg_temp.check((select count(*) from public.vocab_pron_logs where word = 'think') = 2, 'not merged');

-- 4) 21 語以上は断る。配列でないものも断る
do $$
begin
  perform public.save_vocab_pron_logs((select jsonb_agg(jsonb_build_object('word','w'||i,'rating','close','sounds',jsonb_build_array('th'))) from generate_series(1,21) i));
  raise exception 'FAILED: 21 items should fail';
exception when sqlstate '22023' then null;
end $$;
do $$
begin
  perform public.save_vocab_pron_logs('{"word":"x"}'::jsonb);
  raise exception 'FAILED: object should fail';
exception when sqlstate '22023' then null;
end $$;

-- 5) 未来の日時は今にそろえる
select pg_temp.check(public.save_vocab_pron_logs('[{"word":"zoo","rating":"close","sounds":["other"]}]'::jsonb, now() + interval '3 days') = 1, 'future saved');
select pg_temp.check((select taken_at from public.vocab_pron_logs where word = 'zoo') <= now(), 'future clamped');

-- 6) ほかの人には見えない
select pg_temp.as_user(:'B');
select pg_temp.check((select count(*) from public.vocab_pron_logs) = 0, 'B sees nothing');

-- 7) 直接は書けない
do $$
begin
  insert into public.vocab_pron_logs (user_id, word, rating, sounds) values ('22222222-2222-2222-2222-222222222222', 'x', 'close', array['th']);
  raise exception 'FAILED: direct insert should fail';
exception when insufficient_privilege then null;
end $$;

reset role;
select pg_temp.check((select count(*) from public.vocab_pron_logs where user_id = :'A') = 4, 'A has 4 rows');

-- 8) anon は呼べない
set role anon;
do $$
begin
  perform public.save_vocab_pron_logs('[]'::jsonb);
  raise exception 'FAILED: anon should not execute';
exception when insufficient_privilege then null;
end $$;
reset role;

\echo ALL VOCAB PRON TESTS PASSED
