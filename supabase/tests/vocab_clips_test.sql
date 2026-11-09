-- vocab_clips.sql のテスト。手元の PostgreSQL で:
--   cd supabase/tests && psql -X -q -v ON_ERROR_STOP=1 -f vocab_clips_test.sql
-- 最後に "ALL VOCAB_CLIPS TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../vocab_clips.sql

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

-- service role (テーブル所有者) が A の場面を足す
insert into public.vocab_clips (word, video_id, start_ms, end_ms, sentence, channel, source)
values ('apple', 'vid1', 1000, 4000, 'An apple a day.', 'ch', 'channel'),
       ('apple', 'vid2', 2000, 5000, 'Apple pie.', 'ch', 'channel');

set role authenticated;

-- 1) 未ログインは get も add も例外
select pg_temp.as_user('');
do $$ begin
  perform * from public.get_vocab_clips('Asia/Tokyo', array['apple']);
  raise exception 'FAILED: anonymous get should fail';
exception when sqlstate '28000' then null; end $$;
do $$ begin
  perform public.add_vocab_clips('Asia/Tokyo', '[]'::jsonb);
  raise exception 'FAILED: anonymous add should fail';
exception when sqlstate '28000' then null; end $$;

-- 2) ログインした人は get で読める (単語は小文字で比べる)
select pg_temp.as_user(:'A');
select pg_temp.check((select count(*) from public.get_vocab_clips('Asia/Tokyo', array['Apple'])) = 2, 'get reads rows');
select pg_temp.check((select count(*) from public.get_vocab_clips(null, array['nothing'])) = 0, 'get unknown word -> 0');

-- 3) channel と書いても search で入る。大文字の単語は小文字になる
select pg_temp.check(public.add_vocab_clips('Asia/Tokyo',
  '[{"word":"Banana","video_id":"v1","start_ms":0,"end_ms":3000,"sentence":"s","channel":"c","source":"channel"}]') = 1, 'add returns 1');
select pg_temp.check((select source from public.get_vocab_clips(null, array['banana'])) = 'search', 'source forced to search');

-- 4) 同じ場面を 2 回 add しても 1 行
select pg_temp.check(public.add_vocab_clips(null,
  '[{"word":"banana","video_id":"v1","start_ms":0,"end_ms":3000,"sentence":"s","channel":"c"}]') = 0, 'duplicate add returns 0');
select pg_temp.check((select count(*) from public.get_vocab_clips(null, array['banana'])) = 1, 'duplicate -> 1 row');

-- 5) 足りない・おかしい要素は飛ばす
select pg_temp.check(public.add_vocab_clips(null, '[
  {"video_id":"v","start_ms":0,"end_ms":10},
  {"word":"x","start_ms":0,"end_ms":10},
  {"word":"x","video_id":"v","start_ms":10,"end_ms":10},
  {"word":"x","video_id":"v","start_ms":"abc","end_ms":10},
  5, null]') = 0, 'invalid elements skipped');

-- 6) 1 語に 12 場面足しても 10 行
select pg_temp.check(public.add_vocab_clips(null,
  (select jsonb_agg(jsonb_build_object('word','cherry','video_id','v'||g,'start_ms',g*1000,'end_ms',g*1000+2000,'sentence','s','channel','c'))
   from generate_series(1,12) g)) = 10, 'cap 10 per word in one call');
select pg_temp.check(public.add_vocab_clips(null,
  '[{"word":"cherry","video_id":"extra","start_ms":0,"end_ms":10}]') = 0, 'cap holds across calls');
select pg_temp.check((select count(*) from public.get_vocab_clips(null, array['cherry'])) = 10, 'cherry 10 rows');

-- 7) 1 回は 30 要素まで
select pg_temp.check(public.add_vocab_clips(null,
  (select jsonb_agg(jsonb_build_object('word','w'||g,'video_id','v','start_ms',0,'end_ms',10)) from generate_series(1,35) g)) = 30,
  'at most 30 elements per call');

-- 8) get は単語ごとに最大 10 (service role が 12 行入れても)
reset role;
insert into public.vocab_clips (word, video_id, start_ms, end_ms)
select 'plum', 'v'||g, 0, 10 from generate_series(1,12) g;
set role authenticated;
select pg_temp.as_user(:'A');
select pg_temp.check((select count(*) from public.get_vocab_clips(null, array['plum'])) = 10, 'get returns at most 10 per word');

-- 9) 表を直接 select / insert / update / delete できない
do $$ begin
  perform * from public.vocab_clips;
  raise exception 'FAILED: direct select should be denied';
exception when insufficient_privilege then null; end $$;
do $$ begin
  insert into public.vocab_clips (word, video_id, start_ms, end_ms) values ('z','v',0,1);
  raise exception 'FAILED: direct insert should be denied';
exception when insufficient_privilege then null; end $$;
do $$ begin
  delete from public.vocab_clips;
  raise exception 'FAILED: direct delete should be denied';
exception when insufficient_privilege then null; end $$;
do $$ begin
  update public.vocab_clips set sentence = 'x';
  raise exception 'FAILED: direct update should be denied';
exception when insufficient_privilege then null; end $$;
reset role;

-- 10) RLS は有効で、方針は無い
select pg_temp.check((select relrowsecurity from pg_class where oid = 'public.vocab_clips'::regclass), 'RLS enabled');
select pg_temp.check((select count(*) from pg_policies where tablename = 'vocab_clips') = 0, 'no policies');

-- 11) 何度流しても壊れない (行も残る)
select count(*) as before_rows from public.vocab_clips \gset
\i ../vocab_clips.sql
select pg_temp.check((select count(*) from public.vocab_clips) = :before_rows, 'rerun keeps rows');
set role authenticated;
select pg_temp.as_user(:'A');
select pg_temp.check((select count(*) from public.get_vocab_clips(null, array['apple'])) = 2, 'rerun keeps get working');
reset role;

\echo ALL VOCAB_CLIPS TESTS PASSED
