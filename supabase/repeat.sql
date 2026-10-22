-- ============================================================
-- リピーティング練習 (聞いた英文をそのまま言い返す)
--   実行順: schema.sql → summary.sql → topic.sql → repeat.sql
--   何度実行しても壊れない。
-- ============================================================

-- ------------------------------------------------------------
-- 1) 結果の表 (1 文 = 1 行。1 人 500 件まで)
-- ------------------------------------------------------------
create table if not exists public.repeat_results (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  entry_date  date not null,                          -- 練習した日 (夜 3 時区切り)
  created_at  timestamptz not null default now(),
  sentence    text not null check (char_length(sentence) between 1 and 300),
  heard       text not null default '' check (char_length(heard) <= 500),
  accuracy    integer not null check (accuracy between 0 and 100),
  replays     integer not null default 0 check (replays between 0 and 99),
  source      text not null check (source in ('diary', 'summary', 'topic', 'tatoeba')),
  voice       text not null check (voice in ('human', 'gemini', 'device')),
  tatoeba_id  bigint,
  audio_id    bigint
);
create index if not exists repeat_results_user_created_idx
  on public.repeat_results (user_id, created_at desc, id desc);

-- 「やった日」の種類 (schema.sql・topic.sql と同じ 4 種類)
alter table public.activity_days drop constraint if exists activity_days_kind_check;
alter table public.activity_days add constraint activity_days_kind_check
  check (kind in ('diary', 'summary', 'topic', 'repeat'));

alter table public.repeat_results enable row level security;
revoke all on public.repeat_results from anon, authenticated;
grant select on public.repeat_results to authenticated;
drop policy if exists "repeat_results: read own" on public.repeat_results;
create policy "repeat_results: read own" on public.repeat_results
  for select to authenticated using (user_id = (select auth.uid()));

-- ------------------------------------------------------------
-- 2) 内部で使う関数
-- ------------------------------------------------------------

-- 文章を 1 文ずつに分ける: 「. ! ?」の後の空白と改行で区切り、先頭の "- " などを取る。
-- Mr. / Dr. / a.m. / e.g. などの略語の後では区切らない。
-- 4〜10 語・300 文字までの文だけ返す (リピーティングで 1 回聞いて言い返せる長さ)
create or replace function public._split_sentences(p_text text)
returns setof text
language sql
immutable
set search_path = public
as $$
  select s
    from (select btrim(regexp_replace(btrim(part), '^([-*•]|\d+[.)])\s+', '')) as s, n
            from regexp_split_to_table(coalesce(p_text, ''),
                 '(?<!\m(?:[Mm]r|[Mm]rs|[Mm]s|[Dd]r|[Ss]t|[Pp]rof|[Jj]r|[Ss]r|vs|etc|e\.g|i\.e|a\.m|p\.m)\.)(?<=[.!?])\s+|\n+') with ordinality as t(part, n)) x
   where s <> ''
     and char_length(s) <= 300
     and coalesce(array_length(regexp_split_to_array(s, '\s+'), 1), 0) between 4 and 10
   order by n;
$$;

-- 同じ文かどうかを比べるためのキー: 小文字、英数字と空白だけ、空白は 1 つに
create or replace function public._sentence_key(p_text text)
returns text
language sql
immutable
set search_path = public
as $$
  select lower(btrim(regexp_replace(
           regexp_replace(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g'), '[^A-Za-z0-9 ]', '', 'g'),
           ' +', ' ', 'g')));
$$;

-- 文字を扱うだけの関数 (データは読まない)。get_my_repeat_sentences (呼んだ人の権限で動く) から使うので authenticated に許可する
revoke all on function public._split_sentences(text) from public, anon;
revoke all on function public._sentence_key(text) from public, anon;
grant execute on function public._split_sentences(text) to authenticated;
grant execute on function public._sentence_key(text) to authenticated;

-- ------------------------------------------------------------
-- 3) リピーティングをやった日も「やった日」として記録し、連続記録に数える
--    (お題と同じ規則: 次の日なら +1、空いていれば 1、同じ日・過去の日なら変えない)
-- ------------------------------------------------------------
create or replace function public.repeat_counts_as_study()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.streaks%rowtype;
  v_new integer;
begin
  insert into public.activity_days (user_id, day, kind)
  values (new.user_id, new.entry_date, 'repeat')
  on conflict do nothing;

  perform set_config('app.streak_source', 'repeat', true);

  insert into public.streaks (user_id) values (new.user_id)
  on conflict (user_id) do nothing;
  select * into v_row from public.streaks s where s.user_id = new.user_id for update;

  if v_row.last_study_date is null or new.entry_date > v_row.last_study_date then
    if v_row.last_study_date = new.entry_date - 1 then
      v_new := v_row.current_streak + 1;
    else
      v_new := 1;
    end if;
    update public.streaks s
       set current_streak = v_new,
           last_study_date = new.entry_date,
           best_streak = greatest(s.best_streak, s.current_streak, v_new),
           updated_at = now()
     where s.user_id = new.user_id;
  end if;

  perform set_config('app.streak_source', '', true);
  return new;
end;
$$;
revoke all on function public.repeat_counts_as_study() from public, anon, authenticated;

drop trigger if exists repeat_counts_as_study on public.repeat_results;
create trigger repeat_counts_as_study
  after insert on public.repeat_results
  for each row execute function public.repeat_counts_as_study();

-- ------------------------------------------------------------
-- 4) アプリ・Web から呼ぶ関数
-- ------------------------------------------------------------
drop function if exists public.save_repeat_results(text, jsonb, timestamptz);
drop function if exists public.get_my_repeat_sentences(integer, integer, text);
drop function if exists public.get_my_repeat_results(integer);

-- 結果をまとめて保存する (最大 10 件)。保存した件数を返す。
-- p_results: [{sentence, heard, accuracy, replays, source, voice, tatoeba_id, audio_id}]
create function public.save_repeat_results(p_timezone text, p_results jsonb, p_taken_at timestamptz default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_date date;
  v_item jsonb;
  v_text text;
  v_src  text;
  v_voice text;
  v_n    integer := 0;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if p_results is null or jsonb_typeof(p_results) <> 'array' then
    raise exception 'p_results must be an array' using errcode = '22023';
  end if;
  v_date := public._practice_date(p_taken_at, coalesce(p_timezone, 'Asia/Tokyo'));

  for v_item in select value from jsonb_array_elements(p_results) loop
    exit when v_n >= 10;
    continue when jsonb_typeof(v_item) <> 'object';
    v_text := left(btrim(coalesce(v_item->>'sentence', '')), 300);
    continue when v_text = '';
    v_src := coalesce(v_item->>'source', '');
    if v_src not in ('diary', 'summary', 'topic', 'tatoeba') then v_src := 'tatoeba'; end if;
    v_voice := coalesce(v_item->>'voice', '');
    if v_voice not in ('human', 'gemini', 'device') then v_voice := 'device'; end if;

    insert into public.repeat_results (user_id, entry_date, sentence, heard, accuracy, replays, source, voice, tatoeba_id, audio_id)
    values (v_uid, v_date, v_text,
            left(coalesce(v_item->>'heard', ''), 500),
            least(greatest(coalesce((v_item->>'accuracy')::numeric, 0), 0), 100)::integer,
            least(greatest(coalesce((v_item->>'replays')::numeric, 0), 0), 99)::integer,
            v_src, v_voice,
            nullif((v_item->>'tatoeba_id')::numeric, 0)::bigint,
            nullif((v_item->>'audio_id')::numeric, 0)::bigint);
    v_n := v_n + 1;
  end loop;

  -- 1 人 500 件を超えた古いものを消す
  delete from public.repeat_results r
   where r.user_id = v_uid
     and r.id in (select id from public.repeat_results
                   where user_id = v_uid
                   order by created_at desc, id desc
                   offset 500);
  return v_n;
end;
$$;

-- 次の練習に出す文: 言えなかった文 (一番新しい結果が 80% 未満、最大 p_missed 件) と、
-- 自分の添削文 (直近 30 日、直近 7 日に練習した文は除く、ランダムに最大 p_own 件)
create function public.get_my_repeat_sentences(p_missed integer default 2, p_own integer default 2,
                                               p_timezone text default 'Asia/Tokyo')
returns table (sentence text, source text, missed boolean, tatoeba_id bigint, audio_id bigint)
language sql
volatile
security invoker
set search_path = public
as $$
  with t as (
    select public.app_today(coalesce(p_timezone, 'Asia/Tokyo')) as today,
           least(greatest(coalesce(p_missed, 2), 0), 5) as n_missed,
           least(greatest(coalesce(p_own, 2), 0), 5) as n_own
  ),
  latest as (
    select distinct on (public._sentence_key(r.sentence))
           public._sentence_key(r.sentence) as k, r.sentence, r.source, r.tatoeba_id, r.audio_id, r.accuracy, r.created_at, r.id
      from public.repeat_results r
     where r.user_id = (select auth.uid())
     order by public._sentence_key(r.sentence), r.created_at desc, r.id desc
  ),
  missed as (
    select l.k, l.sentence, l.source, l.tatoeba_id, l.audio_id
      from latest l, t
     where l.accuracy < 80
     order by l.created_at desc, l.id desc
     limit (select n_missed from t)
  ),
  recent as (
    select distinct public._sentence_key(r.sentence) as k
      from public.repeat_results r, t
     where r.user_id = (select auth.uid()) and r.entry_date > t.today - 7
  ),
  texts as (
    select 'diary'::text as source, d.corrected_text as body
      from public.diary_entries d, t
     where d.user_id = (select auth.uid()) and d.entry_date > t.today - 30
    union all
    select 'summary', s.improved_summary
      from public.summary_results s, t
     where s.user_id = (select auth.uid()) and s.entry_date > t.today - 30
    union all
    select 'topic', x.corrected
      from public.topic_results x, t
     where x.user_id = (select auth.uid()) and x.entry_date > t.today - 30
  ),
  own_all as (
    select distinct on (public._sentence_key(p.s)) public._sentence_key(p.s) as k, p.s as sentence, tx.source
      from texts tx
      cross join lateral public._split_sentences(tx.body) as p(s)
     order by public._sentence_key(p.s), tx.source
  ),
  own as (
    select o.k, o.sentence, o.source
      from own_all o
     where o.k <> ''
       and o.k not in (select k from recent)
       and o.k not in (select k from missed)
     order by random()
     limit (select n_own from t)
  )
  select m.sentence, m.source, true, m.tatoeba_id, m.audio_id from missed m
  union all
  select o.sentence, o.source, false, null::bigint, null::bigint from own o;
$$;

-- Web 用: 結果を新しい順に
create function public.get_my_repeat_results(p_limit integer default 200)
returns table (id bigint, entry_date date, created_at timestamptz, sentence text, heard text,
               accuracy integer, replays integer, source text, voice text)
language sql
stable
security invoker
set search_path = public
as $$
  select r.id, r.entry_date, r.created_at, r.sentence, r.heard, r.accuracy, r.replays, r.source, r.voice
    from public.repeat_results r
   where r.user_id = (select auth.uid())
   order by r.created_at desc, r.id desc
   limit least(greatest(coalesce(p_limit, 200), 1), 1000);
$$;

revoke all on function public.save_repeat_results(text, jsonb, timestamptz) from public, anon;
revoke all on function public.get_my_repeat_sentences(integer, integer, text) from public, anon;
revoke all on function public.get_my_repeat_results(integer) from public, anon;
grant execute on function public.save_repeat_results(text, jsonb, timestamptz) to authenticated;
grant execute on function public.get_my_repeat_sentences(integer, integer, text) to authenticated;
grant execute on function public.get_my_repeat_results(integer) to authenticated;
