-- topic.sql のテスト。手元の PostgreSQL で:
--   cd supabase/tests && psql -X -q -v ON_ERROR_STOP=1 -f topic_test.sql
-- 最後に "ALL TOPIC TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql

create or replace function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', what; end if;
end $$;

-- ユーザー A として呼ぶ
create or replace function pg_temp.as_user(uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid, false);
end $$;

grant execute on function pg_temp.check(boolean, text) to authenticated;
grant execute on function pg_temp.as_user(text) to authenticated;

\set A '11111111-1111-1111-1111-111111111111'
\set B '22222222-2222-2222-2222-222222222222'
\set M3 '\'[{"type":"tense","wrong":"I go yesterday","fixed":"I went yesterday"}]\''

select pg_temp.as_user(:'A');
set role authenticated;

-- 1) 22 件保存 → 20 件だけ残る
do $$
declare i int;
begin
  for i in 1..22 loop
    perform public.save_topic_result('Asia/Tokyo', 'daily', 'Talk about your weekend ' || i, 45,
      70, 30, 20, 20, 'I go park', 'I went to the park.', 'I went to the park.',
      '- good', '- fix', 'went to', null, '[]'::jsonb, null);
  end loop;
end $$;
select pg_temp.check((select count(*) from public.get_my_topic_results(50)) = 20, 'keeps newest 20 results');
select pg_temp.check((select topic from public.get_my_topic_results(1)) = 'Talk about your weekend 22', 'newest first');

-- 2) 入力の検証
do $$ begin
  perform public.save_topic_result('Asia/Tokyo','daily','t',45, 80,30,20,20,'','','','','','',null,'[]'::jsonb,null);
  raise exception 'FAILED: sum mismatch accepted';
exception when sqlstate '22023' then null; end $$;
do $$ begin
  perform public.save_topic_result('Asia/Tokyo','daily','t',45, 91,41,30,20,'','','','','','',null,'[]'::jsonb,null);
  raise exception 'FAILED: content 41 accepted';
exception when sqlstate '22023' then null; end $$;
do $$ begin
  perform public.save_topic_result('Asia/Tokyo','chat','t',45, 70,30,20,20,'','','','','','',null,'[]'::jsonb,null);
  raise exception 'FAILED: kind chat accepted';
exception when sqlstate '22023' then null; end $$;

-- 3) ミスの正規化: 25 件 → 20 件、未知の種類 → other、300 文字に切る
reset role;
delete from public.mistakes;
set role authenticated;
do $$
declare arr jsonb := '[]'::jsonb; i int;
begin
  arr := arr || jsonb_build_array(jsonb_build_object('type','Spelling','wrong',repeat('x',400),'fixed','y'));
  for i in 2..25 loop
    arr := arr || jsonb_build_array(jsonb_build_object('type','article','wrong','a apple '||i,'fixed','an apple'));
  end loop;
  perform public.save_topic_result('Asia/Tokyo','work','t',60, 70,30,20,20,'','','','','','',null,arr,null);
end $$;
reset role;
select pg_temp.check((select count(*) from public.mistakes) = 20, 'at most 20 mistakes per call');
select pg_temp.check((select type from public.mistakes where wrong like 'xxx%') = 'other', 'unknown type -> other');
select pg_temp.check((select length(wrong) from public.mistakes where wrong like 'xxx%') = 300, 'wrong cut to 300 chars');
select pg_temp.check((select bool_and(source = 'topic') from public.mistakes), 'source = topic');
delete from public.mistakes;
set role authenticated;

-- 4) 苦手の上位
select public.save_mistakes('Asia/Tokyo', 'diary', '[
  {"type":"tense","wrong":"I go","fixed":"I went"},
  {"type":"tense","wrong":"I eat","fixed":"I ate"},
  {"type":"tense","wrong":"I see","fixed":"I saw"},
  {"type":"article","wrong":"a apple","fixed":"an apple"},
  {"type":"article","wrong":"the Japan","fixed":"Japan"},
  {"type":"plural","wrong":"two cat","fixed":"two cats"},
  {"type":"tense","wrong":"","fixed":"skipped (empty wrong)"}]'::jsonb, null) as saved \gset
select pg_temp.check(:saved = 6, 'empty wrong skipped, 6 saved');
select pg_temp.check((select type from public.get_my_weak_points() limit 1) = 'tense', 'top weak point is tense');
select pg_temp.check((select count from public.get_my_weak_points() limit 1) = 3, 'tense count 3');
select pg_temp.check((select count(*) from public.get_my_weak_points()) = 3, 'top 3 only');
do $$ begin
  perform public.save_mistakes('Asia/Tokyo','video','[]'::jsonb,null);
  raise exception 'FAILED: source video accepted';
exception when sqlstate '22023' then null; end $$;

-- 5) 前の期間と、90 日より古いものの削除
reset role;
insert into public.mistakes (user_id, entry_date, source, type, wrong, fixed)
values (:'A', public.app_today('Asia/Tokyo') - 35, 'diary', 'tense', 'old', 'older'),
       (:'A', public.app_today('Asia/Tokyo') - 95, 'diary', 'tense', 'ancient', 'gone');
set role authenticated;
select pg_temp.check((select previous_count from public.get_my_weak_points() where type = 'tense') = 1, 'previous 30 days counted');
select public.save_mistakes('Asia/Tokyo', 'summary', '[{"type":"plural","wrong":"many book","fixed":"many books"}]'::jsonb, null);
reset role;
select pg_temp.check(not exists (select 1 from public.mistakes where wrong = 'ancient'), 'older than 90 days removed');
set role authenticated;

-- 6) Web 用の集計
select pg_temp.check((select count from public.get_my_mistake_stats(30) where type = 'tense') = 3, 'stats count');
select pg_temp.check((select previous_count from public.get_my_mistake_stats(30) where type = 'tense') = 1, 'stats previous');
select pg_temp.check((select jsonb_array_length(examples) from public.get_my_mistake_stats(30) where type = 'tense') = 3, 'stats examples');
select pg_temp.check((select examples->0->>'source' from public.get_my_mistake_stats(30) where type = 'plural') = 'summary', 'newest example first with source');

-- 7) 連続記録とカレンダー
select pg_temp.check((select studied_today from public.get_my_streak('Asia/Tokyo')), 'topic counts for today');
select pg_temp.check((select topic from public.get_my_activity_days(public.app_today('Asia/Tokyo'), public.app_today('Asia/Tokyo'))), 'calendar topic today');
select * from public.complete_study('Asia/Tokyo');
select public.save_summary_result('Asia/Tokyo','v','t',60,80,40,20,20,'a','b','c','d','e','f',null);
select pg_temp.check((select diary and summary and topic from public.get_my_activity_days(public.app_today('Asia/Tokyo'), public.app_today('Asia/Tokyo'))), 'all three on one day');

-- 8) 後から送った古いお題は、連続記録を変えない
reset role;
update public.streaks set current_streak = 4, last_study_date = public.app_today('Asia/Tokyo') - 1 where user_id = :'A';
set role authenticated;
select public.save_topic_result('Asia/Tokyo','exam','late',60, 70,30,20,20,'','','','','','',null,'[]'::jsonb, now() - interval '3 days');
reset role;
select pg_temp.check((select current_streak = 4 and last_study_date = public.app_today('Asia/Tokyo') - 1 from public.streaks where user_id = :'A'), 'late topic does not change streak');
set role authenticated;

-- 9) 言い直しの一致率をあとから入れる
select id as tid from public.get_my_topic_results(1) \gset
select public.set_topic_read_aloud(:tid, 87);
select pg_temp.check((select read_aloud_accuracy from public.get_my_topic_results(1)) = 87, 'read aloud accuracy set');
do $$ begin
  perform public.set_topic_read_aloud(1, 101);
  raise exception 'FAILED: accuracy 101 accepted';
exception when sqlstate '22023' then null; end $$;

-- 10) 他人のデータは読めない・書き換えられない
select pg_temp.as_user(:'B');
select pg_temp.check((select count(*) from public.get_my_topic_results(20)) = 0, 'B sees no topic results');
select pg_temp.check((select count(*) from public.get_my_mistake_stats(90)) = 0, 'B sees no mistakes');
select public.set_topic_read_aloud(:tid, 5);
select pg_temp.as_user(:'A');
select pg_temp.check((select read_aloud_accuracy from public.get_my_topic_results(1)) = 87, 'B cannot change A result');
do $$ begin
  insert into public.mistakes (user_id, entry_date, source, type, wrong, fixed) values (auth.uid(), current_date, 'diary', 'tense', 'a', 'b');
  raise exception 'FAILED: direct insert allowed';
exception when insufficient_privilege then null; end $$;
do $$ begin
  insert into public.topic_results (user_id, entry_date, kind, topic, score) values (auth.uid(), current_date, 'daily', 'x', 1);
  raise exception 'FAILED: direct insert allowed';
exception when insufficient_privilege then null; end $$;

-- 11) もう一度実行しても壊れない
reset role;
select count(*) as before_r from public.topic_results \gset
select count(*) as before_m from public.mistakes \gset
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
select pg_temp.check((select count(*) from public.topic_results) = :before_r, 'rerun keeps results');
select pg_temp.check((select count(*) from public.mistakes) = :before_m, 'rerun keeps mistakes');

\echo ALL TOPIC TESTS PASSED
