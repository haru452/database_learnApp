-- repeat.sql のテスト。手元の PostgreSQL で:
--   cd supabase/tests && psql -X -q -v ON_ERROR_STOP=1 -f repeat_test.sql
-- 最後に "ALL REPEAT TESTS PASSED" と出れば成功。
\set ON_ERROR_STOP 1
\i stub.sql
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql

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

-- 1) 文の分け方: 「. ! ?」の後の空白で区切る。先頭の "- " を取る。4〜25 語・300 文字まで
select pg_temp.check(
  (select array_agg(s) from public._split_sentences(E'I went home. - She has two cats!\nMr. Smith is here today? ok.') s)
  = array['She has two cats!', 'Mr. Smith is here today?'],
  'split: short pieces dropped, "- " removed, no split after "Mr."');
select pg_temp.check(
  (select array_agg(s) from public._split_sentences('I talked with Mr. Tanaka about the new project. I got up at 6 a.m. and ran. We met Dr. Brown, e.g. at the station.') s)
  = array['I talked with Mr. Tanaka about the new project.', 'I got up at 6 a.m. and ran.',
          'We met Dr. Brown, e.g. at the station.'],
  'split: abbreviations (Mr. / a.m. / Dr. / e.g.) do not end a sentence');
select pg_temp.check(
  (select count(*) from public._split_sentences('one two three four five six seven eight nine ten eleven.')) = 0,
  'split: more than 10 words dropped (too long to repeat)');
select pg_temp.check(
  (select count(*) from public._split_sentences('one two three four five six seven eight nine ten.')) = 1,
  'split: 10 words kept');
select pg_temp.check(public._sentence_key('  She HAS two-cats! ') = 'she has twocats', 'key: lower, letters/digits/spaces only');

-- 2) 保存: 最大 10 件、範囲の丸め、知らない値
select pg_temp.as_user(:'A');
set role authenticated;
select pg_temp.check(public.save_repeat_results('Asia/Tokyo', (
  select jsonb_agg(jsonb_build_object('sentence', 'Sentence number ' || i || ' is here.', 'heard', 'x',
                   'accuracy', 150, 'replays', -3, 'source', 'web', 'voice', 'robot', 'tatoeba_id', 7, 'audio_id', 9))
  from generate_series(1, 12) i) || '[{"sentence":"  ","accuracy":50}]'::jsonb, null) = 10, 'save: max 10 rows');
select pg_temp.check((select bool_and(accuracy = 100 and replays = 0 and source = 'tatoeba' and voice = 'device' and audio_id = 9)
                        from public.repeat_results), 'save: clamped and unknown values mapped');

-- 3) 今日やった → 連続記録とカレンダー
select pg_temp.check((select studied_today from public.get_my_streak('Asia/Tokyo')), 'repeat counts as study today');
select pg_temp.check((select repeat from public.get_my_activity_days(public.app_today('Asia/Tokyo'), public.app_today('Asia/Tokyo'))),
                     'activity day has repeat');

-- 4) 言えなかった文: 一番新しい結果が 80% 未満のものだけ。もとの source / audio_id のまま
select public.save_repeat_results('Asia/Tokyo',
  '[{"sentence":"Could you send me the file?","accuracy":60,"source":"tatoeba","voice":"human","tatoeba_id":11,"audio_id":22}]'::jsonb, null);
select public.save_repeat_results('Asia/Tokyo',
  '[{"sentence":"could you SEND me the file","accuracy":90,"source":"tatoeba","voice":"human","tatoeba_id":11,"audio_id":22}]'::jsonb, null);
select public.save_repeat_results('Asia/Tokyo',
  '[{"sentence":"I have lived here for three years.","accuracy":70,"source":"topic","voice":"gemini"}]'::jsonb, null);
select pg_temp.check((select array_agg(sentence) from public.get_my_repeat_sentences(2, 0) where missed)
                     = array['I have lived here for three years.'], 'missed: only latest < 80');
select pg_temp.check((select source from public.get_my_repeat_sentences(2, 0) where missed) = 'topic', 'missed keeps source');

-- 5) 自分の添削文: 直近 30 日、直近 7 日に練習した文は除く
reset role;
insert into public.diary_entries (user_id, entry_date, original_text, corrected_text)
values (:'A', public.app_today('Asia/Tokyo'), 'x',
        'I went to the big park. She cooked dinner for us. We watched a long movie.');
insert into public.topic_results (user_id, entry_date, kind, score, corrected)
values (:'A', public.app_today('Asia/Tokyo') - 40, 'daily', 50, 'This old sentence must not appear.');
insert into public.repeat_results (user_id, entry_date, sentence, accuracy, source, voice)
values (:'A', public.app_today('Asia/Tokyo') - 3, 'We watched a long movie.', 95, 'diary', 'gemini');
select pg_temp.as_user(:'A');
set role authenticated;
select pg_temp.check((select count(*) from public.get_my_repeat_sentences(0, 5) where not missed) = 2, 'own: 2 candidates');
select pg_temp.check((select bool_and(source = 'diary') from public.get_my_repeat_sentences(0, 5) where not missed), 'own: source diary');
select pg_temp.check(not exists (select 1 from public.get_my_repeat_sentences(0, 5) where sentence like 'We watched%'),
                     'own: practiced in last 7 days excluded');
select pg_temp.check(not exists (select 1 from public.get_my_repeat_sentences(0, 5) where sentence like 'This old%'),
                     'own: older than 30 days excluded');
select pg_temp.check((select count(*) from public.get_my_repeat_sentences(2, 1)) = 2, 'limits: 1 missed + 1 own');

-- 6) 過去の日付で保存 → その日が repeat、連続記録の最後の日は変わらない
select public.save_repeat_results('Asia/Tokyo', '[{"sentence":"An old practice sentence here.","accuracy":85}]'::jsonb,
                                  now() - interval '2 days');
select pg_temp.check((select repeat from public.get_my_activity_days(public.app_today('Asia/Tokyo') - 2, public.app_today('Asia/Tokyo') - 2)),
                     'past day recorded as repeat');
select pg_temp.check((select last_date from public.get_my_streak('Asia/Tokyo')) = public.app_today('Asia/Tokyo'), 'streak end unchanged');

-- 7) 1 人 500 件まで
select public.save_repeat_results('Asia/Tokyo', (select jsonb_agg(jsonb_build_object('sentence', 'Bulk sentence ' || b || '-' || i || ' ok.', 'accuracy', 90))
                                                 from generate_series(1, 10) i), null)
  from generate_series(1, 52) b;
select pg_temp.check((select count(*) from public.get_my_repeat_results(1000)) = 500, 'keeps 500 rows');

-- 8) ほかの人には見えない、直接書けない
select pg_temp.as_user(:'B');
select pg_temp.check((select count(*) from public.get_my_repeat_results(1000)) = 0, 'B sees no results');
select pg_temp.check((select count(*) from public.get_my_repeat_sentences(5, 5)) = 0, 'B gets no sentences');
do $$ begin
  insert into public.repeat_results (user_id, entry_date, sentence, accuracy, source, voice)
  values (auth.uid(), current_date, 'x', 1, 'tatoeba', 'device');
  raise exception 'FAILED: direct insert allowed';
exception when insufficient_privilege then null; end $$;

-- 9) もう一度実行しても壊れない (topic.sql だけ後から実行しても repeat の行が残る)
reset role;
select count(*) as before_r from public.repeat_results \gset
\i ../schema.sql
\i ../summary.sql
\i ../topic.sql
\i ../repeat.sql
\i ../topic.sql
select pg_temp.check((select count(*) from public.repeat_results) = :before_r, 'rerun keeps results');
select pg_temp.check(exists (select 1 from public.activity_days where kind = 'repeat'), 'rerun keeps repeat days');

-- 10) シャドーイング: mode 列 (既定 repeat)、source bbc、英文と言った内容は保存しない (点数だけ)、言えなかった文に shadow を混ぜない
select pg_temp.as_user(:'A');
set role authenticated;
select public.save_repeat_results('Asia/Tokyo',
  '[{"sentence":"Shadow sentence about the weather today.","heard":"shadow sentence","accuracy":50,"source":"bbc","voice":"human","mode":"shadow"},
    {"sentence":"Plain repeat sentence for the mode test.","accuracy":90,"source":"tatoeba","voice":"human"},
    {"sentence":"Odd mode sentence for the test here.","accuracy":90,"source":"tatoeba","voice":"human","mode":"x"}]'::jsonb, null);
select pg_temp.check((select count(*) from public.repeat_results where mode = 'shadow') = 1, 'mode shadow saved (even with text)');
select pg_temp.check((select source from public.repeat_results where mode = 'shadow') = 'bbc', 'source bbc saved');
select pg_temp.check((select sentence from public.repeat_results where mode = 'shadow') = '', 'shadow: sentence not stored');
select pg_temp.check((select heard from public.repeat_results where mode = 'shadow') = '', 'shadow: heard not stored');
select pg_temp.check((select accuracy from public.repeat_results where mode = 'shadow') = 50, 'shadow: score stored');
select pg_temp.check(not exists (select 1 from public.repeat_results where sentence like 'Shadow sentence%'), 'BBC text nowhere in the table');
select pg_temp.check((select mode from public.repeat_results where sentence like 'Plain repeat%') = 'repeat', 'mode defaults to repeat');
select pg_temp.check((select mode from public.repeat_results where sentence like 'Odd mode%') = 'repeat', 'unknown mode -> repeat');
select pg_temp.check(not exists (select 1 from public.get_my_repeat_sentences(5, 0) where sentence = ''),
                     'shadow rows never come back as missed');
select pg_temp.check((select count(*) from public.get_my_repeat_results(1000) where mode = 'shadow' and sentence = '') = 1,
                     'results return mode (no text for shadow)');
select pg_temp.check(public.save_repeat_results('Asia/Tokyo', '[{"sentence":"","accuracy":10}]'::jsonb, null) = 0,
                     'empty sentence still skipped for repeat');
reset role;
-- 前の版で英文付きで保存された shadow の行は、repeat.sql を実行し直すと英文が消える
alter table public.repeat_results drop constraint repeat_results_sentence_check;   -- 前の版の状態に戻す
update public.repeat_results set sentence = 'Earlier shadow text.' where mode = 'shadow';
alter table public.repeat_results add constraint repeat_results_sentence_check check (char_length(sentence) between 1 and 300);
insert into public.repeat_results (user_id, entry_date, sentence, heard, accuracy, source, voice, mode)
values (:'A', current_date, 'Old shadow text from before.', 'old shadow', 60, 'bbc', 'human', 'shadow');
\i ../repeat.sql
select pg_temp.check((select count(*) from public.repeat_results where mode = 'shadow') = 2, 'rerun keeps mode column and rows');
select pg_temp.check(not exists (select 1 from public.repeat_results where mode = 'shadow' and (sentence <> '' or heard <> '')),
                     'rerun removes old shadow text');

-- 11) アプリはシャドーイングのとき p_version 2 を送る (mode の無い古いサーバーでは関数が見つからず、端末に一時保存される)
select pg_temp.as_user(:'A');
set role authenticated;
select pg_temp.check(public.save_repeat_results(p_timezone => 'Asia/Tokyo',
  p_results => '[{"sentence":"Second shadow sentence with a version.","accuracy":70,"source":"bbc","voice":"human","mode":"shadow"}]'::jsonb,
  p_taken_at => null, p_version => 2) = 1, 'save with p_version 2');
reset role;
select pg_temp.check((select count(*) from pg_proc where proname = 'save_repeat_results') = 1, 'only one save_repeat_results (old signature dropped)');

\echo ALL REPEAT TESTS PASSED
