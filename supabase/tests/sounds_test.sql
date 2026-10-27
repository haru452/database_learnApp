-- sounds.sql のテスト。手元の PostgreSQL で:
--   cd supabase/tests && psql -X -q -v ON_ERROR_STOP=1 -f sounds_test.sql
-- 最後に "ALL SOUNDS TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
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

-- 1) その他の名前のそろえ方 (アプリの SoundTypes.NormalizeOtherName と同じ)
select pg_temp.check(public._sound_label('Z sound (zoo)') = 'z', 'label: Z sound (zoo) -> z');
select pg_temp.check(public._sound_label('The "W" Sound') = 'the w', 'label: The "W" Sound -> the w');
select pg_temp.check(public._sound_label('NG sounds') = 'ng', 'label: NG sounds -> ng');
select pg_temp.check(public._sound_label('(x)') = '', 'label: only brackets -> empty');
select pg_temp.check(public._sound_label('  Dark   L / clear-L  ') = 'dark l / clear-l', 'label: spaces, / and - kept');
select pg_temp.check(char_length(public._sound_label(repeat('ab ', 30))) <= 30, 'label: 30 chars max');

-- 2) 保存の丸め
select pg_temp.as_user(:'A');
set role authenticated;
select pg_temp.check(public.save_pronunciation_issues('Asia/Tokyo',
  (select jsonb_agg(jsonb_build_object('sound', 'th', 'weight', 1, 'word', 'think', 'source', 'repeat')) from generate_series(1, 25))) = 20,
  'save: 20 per call');
reset role;
delete from public.pronunciation_issues;
set role authenticated;
select pg_temp.check(public.save_pronunciation_issues('Asia/Tokyo', '[
  {"sound":"xx","weight":3,"word":"a","source":"check"},
  {"sound":"other","label":"(only)","weight":3,"word":"b","source":"check"},
  {"sound":"th","label":"should go","weight":2,"word":"thinkthinkthinkthinkthinkthinkthinkthinkthink","source":"x"}
]'::jsonb) = 1, 'save: unknown sound and empty other skipped');
select pg_temp.check((select label from public.pronunciation_issues) = '', 'save: th label empty');
select pg_temp.check((select weight from public.pronunciation_issues) = 1, 'save: weight 2 -> 1');
select pg_temp.check((select char_length(word) from public.pronunciation_issues) = 40, 'save: word 40 chars');
select pg_temp.check((select source from public.pronunciation_issues) = 'repeat', 'save: unknown source -> repeat');
reset role;
delete from public.pronunciation_issues;

-- 3) 集計
set role authenticated;
select public.save_pronunciation_issues('Asia/Tokyo', '[
  {"sound":"th","weight":3,"word":"think","source":"check"},
  {"sound":"th","weight":3,"word":"three","source":"check"},
  {"sound":"th","weight":3,"word":"think","source":"check"},
  {"sound":"r_l","weight":1,"word":"right","source":"repeat"},
  {"sound":"r_l","weight":1,"word":"play","source":"repeat"},
  {"sound":"other","label":"Z sound (zoo)","weight":3,"word":"zoo","source":"check"},
  {"sound":"other","label":"NG sounds","weight":1,"word":"","source":"check"}
]'::jsonb);
select pg_temp.check((select array_agg(sound || ':' || label || ':' || points order by points desc, sound, label)
                        from public.get_my_weak_sounds(30, 'Asia/Tokyo'))
                     = array['th::9', 'other:z:3', 'r_l::2', 'other:ng:1'], 'weak: points per sound/label, other split by name');
select pg_temp.check((select sound from public.get_my_weak_sounds(30, 'Asia/Tokyo') limit 1) = 'th', 'weak: ordered by points');
select pg_temp.check((select words from public.get_my_weak_sounds(30, 'Asia/Tokyo') where sound = 'th') = '["think", "three"]'::jsonb,
                     'weak: words newest first, no repeats');
select pg_temp.check((select words from public.get_my_weak_sounds(30, 'Asia/Tokyo') where label = 'ng') = '[]'::jsonb, 'weak: empty word not listed');
reset role;
-- 35 日前 (前の 30 日に入る)
insert into public.pronunciation_issues (user_id, entry_date, sound, label, weight, word, source)
values (:'A', public.app_today('Asia/Tokyo') - 35, 'th', '', 3, 'old', 'check');
set role authenticated;
select pg_temp.check((select previous_points from public.get_my_weak_sounds(30, 'Asia/Tokyo') where sound = 'th') = 3, 'weak: previous 30 days');
select pg_temp.check((select previous_points from public.get_my_weak_sounds(30, 'Asia/Tokyo') where sound = 'r_l') = 0, 'weak: previous 0 when none');
select pg_temp.check((select previous_points from public.get_my_weak_sounds(90, 'Asia/Tokyo') where sound = 'th') is null, 'weak: previous null over 45 days');
select pg_temp.check((select points from public.get_my_weak_sounds(7, 'Asia/Tokyo') where sound = 'th') = 9, 'weak: 7 days');
-- words は最大 5
select public.save_pronunciation_issues('Asia/Tokyo', (select jsonb_agg(jsonb_build_object('sound', 'v_b', 'weight', 1, 'word', 'w' || g, 'source', 'repeat')) from generate_series(1, 8) g));
select pg_temp.check((select jsonb_array_length(words) from public.get_my_weak_sounds(30, 'Asia/Tokyo') where sound = 'v_b') = 5, 'weak: words max 5');
reset role;

-- 4) 古いもの (95 日前) と 500 件を超えたものは、保存のたびに消える
insert into public.pronunciation_issues (user_id, entry_date, sound, label, weight, word, source)
values (:'A', public.app_today('Asia/Tokyo') - 95, 'th', '', 3, 'ancient', 'check');
insert into public.pronunciation_issues (user_id, entry_date, sound, label, weight, word, source)
select :'A', public.app_today('Asia/Tokyo'), 'f_h', '', 1, 'f' || g, 'repeat' from generate_series(1, 510) g;
set role authenticated;
select public.save_pronunciation_issues('Asia/Tokyo', '[{"sound":"s_sh","weight":1,"word":"she","source":"repeat"}]'::jsonb);
reset role;
select pg_temp.check(not exists (select 1 from public.pronunciation_issues where word = 'ancient'), 'cleanup: older than 90 days removed');
select pg_temp.check((select count(*) from public.pronunciation_issues where user_id = :'A') = 500, 'cleanup: 500 per person');
select pg_temp.check(exists (select 1 from public.pronunciation_issues where word = 'she'), 'cleanup: newest kept');

-- 5) ほかの人には見えない・直接は書けない・ログインなしは不可
select pg_temp.as_user(:'B');
set role authenticated;
select pg_temp.check((select count(*) from public.get_my_weak_sounds(90, 'Asia/Tokyo')) = 0, 'B sees nothing via function');
select pg_temp.check((select count(*) from public.pronunciation_issues) = 0, 'B sees nothing via table');
do $$ begin
  insert into public.pronunciation_issues (user_id, entry_date, sound, weight, source)
  values ('22222222-2222-2222-2222-222222222222', current_date, 'th', 3, 'check');
  raise exception 'FAILED: direct insert allowed';
exception when insufficient_privilege then null;
end $$;
reset role;
select pg_temp.as_user('');
set role authenticated;
do $$ begin
  perform public.save_pronunciation_issues('Asia/Tokyo', '[]'::jsonb);
  raise exception 'FAILED: anonymous save allowed';
exception when others then
  if sqlerrm like 'FAILED%' then raise; end if;
end $$;
reset role;

-- 6) 連続記録・カレンダーには数えない
select pg_temp.check(not exists (select 1 from public.activity_days where user_id = :'A'), 'not counted as a study day');

-- 7) 何度実行しても壊れない
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../sounds.sql
select pg_temp.check((select count(*) from public.pronunciation_issues where user_id = :'A') = 500, 'rerun keeps rows');

\echo ALL SOUNDS TESTS PASSED
