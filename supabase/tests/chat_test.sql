-- chat.sql のテスト。手元の PostgreSQL で:
--   cd supabase/tests && psql -X -q -v ON_ERROR_STOP=1 -f chat_test.sql
-- 最後に "ALL CHAT TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../vocab.sql
\i ../answer.sql
\i ../karaoke.sql
\i ../talk.sql
\i ../chat.sql

create or replace function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', what; end if;
end $$;
create or replace function pg_temp.as_user(uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid, false);
end $$;
create or replace function pg_temp.today() returns date language sql as $$ select public.app_today('Asia/Tokyo') $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;
grant execute on function pg_temp.as_user(text) to authenticated;
grant execute on function pg_temp.today() to authenticated;

\set A '11111111-1111-1111-1111-111111111111'
\set B '22222222-2222-2222-2222-222222222222'
\set M '[{"type":"article","wrong":"the karaoke","fixed":"karaoke","note":"x"},{"type":"plural","wrong":"Japanese song","fixed":"Japanese songs"},{"type":"pronunciation","wrong":"raisins","fixed":"rhythm"},{"type":"tense","wrong":"","fixed":"y"}]'

set role authenticated;

-- 1) 未ログインは使えない
select pg_temp.as_user('');
do $$
begin
  perform public.save_chat_day('x.json', public.app_today('Asia/Tokyo'));
  raise exception 'FAILED: anonymous call should fail';
exception when sqlstate '28000' then null;
end $$;

-- 2) 3 日前のファイル → ミス 3 件 (空の wrong は飛ばす、知らない種類は other)、連続記録 1
select pg_temp.as_user(:'A');
select pg_temp.check((select saved from public.save_chat_day('d3.json', pg_temp.today() - 3, :'M')) = 3, 'saved 3 mistakes');
select pg_temp.check((select count(*) from public.mistakes where source = 'chat') = 3, '3 chat mistakes');
select pg_temp.check((select count(*) from public.mistakes where type = 'other' and fixed = 'rhythm') = 1, 'unknown type -> other');
select pg_temp.check((select entry_date from public.mistakes limit 1) = pg_temp.today() - 3, 'date is file date');
select pg_temp.check((select streak from public.get_my_streak('Asia/Tokyo')) = 0, 'old day only -> shown streak 0');

-- 3) 同じファイルをもう一度 → 何もしない
select pg_temp.check((select already_sent from public.save_chat_day('d3.json', pg_temp.today() - 3, :'M')) = true, 'resend -> already sent');
select pg_temp.check((select count(*) from public.mistakes) = 3, 'resend adds nothing');

-- 4) 今日、アプリで Talk をした (2 日前と昨日が空いているので 1)
select pg_temp.check((select streak from public.complete_talk_session('Asia/Tokyo')) = 1, 'talk today -> 1');

-- 5) パソコンが切れていた 2 日分 (2 日前・昨日) をあとで送る → つながって 4
select pg_temp.check((select streak from public.save_chat_day('d1.json', pg_temp.today() - 1, '[]')) = 2, 'yesterday + today -> 2 (gap at -2)');
select pg_temp.check((select streak from public.save_chat_day('d2.json', pg_temp.today() - 2)) = 4, 'gap filled -> 4');
select pg_temp.check((select streak from public.get_my_streak('Asia/Tokyo')) = 4, 'shown streak 4');
select pg_temp.check((select best_streak from public.get_my_streak('Asia/Tokyo')) = 4, 'best 4');
select pg_temp.check((select count(*) from public.activity_days where kind = 'chat') = 3, '3 chat days');
select pg_temp.check((select chat and not diary from public.get_my_activity_days(pg_temp.today() - 2, pg_temp.today() - 2)), 'calendar chat column');
select pg_temp.check((select not chat from public.get_my_activity_days(pg_temp.today(), pg_temp.today())), 'talk day is not chat');

-- 6) 今日のファイル → 同じ日なので 4 のまま。明日 (3 時前の夜更かし分) も受け付ける
select pg_temp.check((select streak from public.save_chat_day('d0.json', pg_temp.today())) = 4, 'same day -> 4');
select pg_temp.check((select streak from public.save_chat_day('d+1.json', pg_temp.today() + 1)) = 5, 'next day -> 5');

-- 7) 未来すぎる日・古すぎる日・空のファイル名は断る
do $$
begin
  perform public.save_chat_day('f.json', public.app_today('Asia/Tokyo') + 2);
  raise exception 'FAILED: future date should fail';
exception when sqlstate '22023' then null;
end $$;
do $$
begin
  perform public.save_chat_day('o.json', public.app_today('Asia/Tokyo') - 91);
  raise exception 'FAILED: old date should fail';
exception when sqlstate '22023' then null;
end $$;
do $$
begin
  perform public.save_chat_day('  ', public.app_today('Asia/Tokyo'));
  raise exception 'FAILED: empty key should fail';
exception when sqlstate '22023' then null;
end $$;
select pg_temp.check((select count(*) from public.chat_uploads) = 5, 'rejected calls store nothing');

-- 8) よくあるミスに chat の例が出る
select pg_temp.check((select bool_or(e->>'source' = 'chat') from public.get_my_mistake_stats(30), jsonb_array_elements(examples) e),
  'mistake stats show chat');

-- 9) ほかの人には見えない・入らない
select pg_temp.as_user(:'B');
select pg_temp.check((select count(*) from public.chat_uploads) = 0, 'B sees no uploads');
select pg_temp.check((select count(*) from public.mistakes) = 0, 'B sees no mistakes');
select pg_temp.check((select already_sent from public.save_chat_day('d3.json', pg_temp.today() - 3)) = false, 'same key is per user');

-- 10) 表に直接は書けない。anon は呼べない
do $$
begin
  insert into public.chat_uploads (user_id, file_key, entry_date)
  values ('22222222-2222-2222-2222-222222222222', 'z', current_date);
  raise exception 'FAILED: direct insert should fail';
exception when insufficient_privilege then null;
end $$;
reset role;
set role anon;
do $$
begin
  perform public.save_chat_day('a.json', current_date);
  raise exception 'FAILED: anon should not execute';
exception when insufficient_privilege then null;
end $$;
reset role;

-- 11) 何度実行しても壊れない (ほかの .sql を後から実行しても chat の行で制約違反にならない)
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../vocab.sql
\i ../answer.sql
\i ../karaoke.sql
\i ../talk.sql
\i ../chat.sql
select pg_temp.check((select count(*) from public.activity_days where kind = 'chat') >= 4, 'rerun keeps chat rows');
select pg_temp.check((select count(*) from public.mistakes where source = 'chat') >= 3, 'rerun keeps chat mistakes');
set role authenticated;
select pg_temp.as_user(:'A');
select pg_temp.check((select bool_or(chat) from public.get_my_activity_days(pg_temp.today() - 10, pg_temp.today() + 1)), 'rerun keeps chat column');
reset role;

\echo ALL CHAT TESTS PASSED
