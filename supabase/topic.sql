-- ============================================================
-- 追加: お題スピーキングの結果と、よくあるミスの集計
-- Supabase の SQL Editor に貼り付けて Run (何度実行してもよい。データは消えない)。
-- ※ schema.sql → summary.sql → このファイル の順に実行すること。
--
--   save_topic_result      … アプリ: お題スピーキングの結果 (とミス) を1件保存する
--   set_topic_read_aloud   … アプリ: 言い直しの一致率を、あとから入れる
--   save_mistakes          … アプリ: 日記・要約の添削で見つかったミスを保存する
--   get_my_topic_results   … Web  : お題スピーキングの結果 (新しい順)
--   get_my_weak_points     … アプリ: 直近30日で多いミスの種類 (上位3つ)
--   get_my_mistake_stats   … Web  : 期間内のミスの種類ごとの回数と例
--
-- 容量を節約するため、結果は1人あたり新しい 20 件、ミスは直近 90 日・最大 500 件だけ残す。
-- 表は本人の行を「読む」ことだけ許可し、書き込みは関数経由だけにする。
-- 日付は夜中の 3:00 までを前の日として数える (日記の連続記録と同じ区切り)。
-- ============================================================

-- ------------------------------------------------------------
-- 表
-- ------------------------------------------------------------
create table if not exists public.topic_results (
  id                  bigint generated always as identity primary key,
  user_id             uuid not null default auth.uid() references auth.users (id) on delete cascade,
  entry_date          date not null,
  created_at          timestamptz not null default now(),
  kind                text not null check (kind in ('exam', 'daily', 'work')),
  topic               text not null default '',
  time_limit_seconds  integer not null default 60,
  score               integer not null check (score between 0 and 100),
  content_score       integer check (content_score between 0 and 40),
  organization_score  integer check (organization_score between 0 and 30),
  language_score      integer check (language_score between 0 and 30),
  transcript          text not null default '',
  corrected           text not null default '',
  natural_version     text not null default '',
  good_points         text not null default '',
  fix_points          text not null default '',
  phrases             text not null default '',
  read_aloud_accuracy integer check (read_aloud_accuracy between 0 and 100)
);
create index if not exists topic_results_user_created_idx
  on public.topic_results (user_id, created_at desc);

create table if not exists public.mistakes (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  entry_date  date not null,
  created_at  timestamptz not null default now(),
  source      text not null check (source in ('diary', 'summary', 'topic')),
  type        text not null check (type in ('article', 'tense', 'preposition', 'agreement', 'plural',
                                            'verb_form', 'word_order', 'word_choice', 'missing_word', 'other')),
  wrong       text not null check (char_length(wrong) between 1 and 300),
  fixed       text not null check (char_length(fixed) between 1 and 300)
);
create index if not exists mistakes_user_date_idx on public.mistakes (user_id, entry_date desc);

-- 「やった日」の種類に topic を足す (schema.sql と同じ。古い schema.sql のままでも、お題を保存できるように)
alter table public.activity_days drop constraint if exists activity_days_kind_check;
alter table public.activity_days add constraint activity_days_kind_check
  check (kind in ('diary', 'summary', 'topic'));

alter table public.topic_results enable row level security;
alter table public.mistakes enable row level security;

drop policy if exists "topic_results: read own" on public.topic_results;
create policy "topic_results: read own" on public.topic_results
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "mistakes: read own" on public.mistakes;
create policy "mistakes: read own" on public.mistakes
  for select to authenticated using (user_id = (select auth.uid()));

revoke all on public.topic_results from anon, authenticated;
revoke all on public.mistakes from anon, authenticated;
grant select on public.topic_results to authenticated;
grant select on public.mistakes to authenticated;

-- ------------------------------------------------------------
-- 内部用 (直接は呼べない)
-- ------------------------------------------------------------

-- 練習した日時 → 記録する日付。未来や古すぎる (30日より前) 日時は今にする
create or replace function public._practice_date(p_taken_at timestamptz, p_timezone text)
returns date
language plpgsql
stable
set search_path = public
as $$
declare
  v_taken timestamptz := coalesce(p_taken_at, now());
begin
  if v_taken > now() + interval '5 minutes' or v_taken < now() - interval '30 days' then
    v_taken := now();
  end if;
  begin
    return ((v_taken at time zone p_timezone) - interval '3 hours')::date;
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;
end;
$$;

-- ミスを保存する (最大 20 件。知らない種類は other、文は 300 文字まで、空のものは飛ばす)。
-- そのあと、90 日より古いものと、1人 500 件を超えた古いものを消す。保存した件数を返す
create or replace function public._insert_mistakes(p_uid uuid, p_date date, p_source text, p_mistakes jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  v_item  jsonb;
  v_type  text;
  v_wrong text;
  v_fixed text;
begin
  if p_mistakes is null or jsonb_typeof(p_mistakes) <> 'array' then
    return 0;
  end if;

  for v_item in select value from jsonb_array_elements(p_mistakes) with ordinality as e(value, n)
                where n <= 20 order by n loop
    if jsonb_typeof(v_item) <> 'object' then continue; end if;
    v_type  := lower(trim(coalesce(v_item->>'type', '')));
    v_wrong := left(trim(coalesce(v_item->>'wrong', '')), 300);
    v_fixed := left(trim(coalesce(v_item->>'fixed', '')), 300);
    if v_wrong = '' or v_fixed = '' then continue; end if;
    if v_type not in ('article', 'tense', 'preposition', 'agreement', 'plural',
                      'verb_form', 'word_order', 'word_choice', 'missing_word', 'other') then
      v_type := 'other';
    end if;
    insert into public.mistakes (user_id, entry_date, source, type, wrong, fixed)
    values (p_uid, p_date, p_source, v_type, v_wrong, v_fixed);
    v_count := v_count + 1;
  end loop;

  delete from public.mistakes m
   where m.user_id = p_uid and m.entry_date < public.app_today('Asia/Tokyo') - 90;
  delete from public.mistakes m
   where m.user_id = p_uid
     and m.id not in (select m2.id from public.mistakes m2 where m2.user_id = p_uid
                       order by m2.created_at desc, m2.id desc limit 500);
  return v_count;
end;
$$;

revoke all on function public._practice_date(timestamptz, text) from public, anon, authenticated;
revoke all on function public._insert_mistakes(uuid, date, text, jsonb) from public, anon, authenticated;

-- ------------------------------------------------------------
-- お題スピーキングをやった日も「やった日」として記録し、連続記録に数える
-- (要約練習と同じ規則: 次の日なら +1、空いていれば 1、同じ日・過去の日なら変えない)
-- ------------------------------------------------------------
create or replace function public.topic_counts_as_study()
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
  values (new.user_id, new.entry_date, 'topic')
  on conflict do nothing;

  perform set_config('app.streak_source', 'topic', true);

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
revoke all on function public.topic_counts_as_study() from public, anon, authenticated;

drop trigger if exists topic_counts_as_study on public.topic_results;
create trigger topic_counts_as_study
  after insert on public.topic_results
  for each row execute function public.topic_counts_as_study();

-- ------------------------------------------------------------
-- アプリ用
-- ------------------------------------------------------------
drop function if exists public.save_topic_result(text, text, text, integer, integer, integer, integer, integer,
  text, text, text, text, text, text, integer, jsonb, timestamptz);
drop function if exists public.set_topic_read_aloud(bigint, integer);
drop function if exists public.set_topic_read_aloud(bigint, integer, text);
drop function if exists public.save_mistakes(text, text, jsonb, timestamptz);
drop function if exists public.get_my_topic_results(integer);
drop function if exists public.get_my_weak_points();
drop function if exists public.get_my_weak_points(text);
drop function if exists public.get_my_mistake_stats(integer);

create function public.save_topic_result(
  p_timezone            text default 'Asia/Tokyo',
  p_kind                text default 'daily',
  p_topic               text default '',
  p_time_limit          integer default 60,
  p_score               integer default 0,
  p_content_score       integer default 0,
  p_organization_score  integer default 0,
  p_language_score      integer default 0,
  p_transcript          text default '',
  p_corrected           text default '',
  p_natural             text default '',
  p_good_points         text default '',
  p_fix_points          text default '',
  p_phrases             text default '',
  p_read_aloud_accuracy integer default null,
  p_mistakes            jsonb default '[]'::jsonb,
  p_taken_at            timestamptz default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_date  date;
  v_taken timestamptz;
  v_id    bigint;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_kind is null or p_kind not in ('exam', 'daily', 'work') then
    raise exception 'invalid kind' using errcode = '22023';
  end if;
  if p_content_score is null or p_organization_score is null or p_language_score is null
     or p_content_score not between 0 and 40
     or p_organization_score not between 0 and 30
     or p_language_score not between 0 and 30 then
    raise exception 'invalid score breakdown' using errcode = '22023';
  end if;
  if p_score is distinct from p_content_score + p_organization_score + p_language_score then
    raise exception 'score does not match the breakdown' using errcode = '22023';
  end if;
  if p_read_aloud_accuracy is not null and p_read_aloud_accuracy not between 0 and 100 then
    raise exception 'invalid read aloud accuracy' using errcode = '22023';
  end if;

  v_taken := coalesce(p_taken_at, now());
  if v_taken > now() + interval '5 minutes' or v_taken < now() - interval '30 days' then
    v_taken := now();
  end if;
  v_date := public._practice_date(v_taken, p_timezone);

  if (select count(*) from public.topic_results r
       where r.user_id = v_uid and r.entry_date = v_date) >= 100 then
    raise exception 'too many results today' using errcode = '54000';
  end if;

  insert into public.topic_results as r (
    user_id, entry_date, created_at, kind, topic, time_limit_seconds,
    score, content_score, organization_score, language_score,
    transcript, corrected, natural_version, good_points, fix_points, phrases, read_aloud_accuracy)
  values (
    v_uid, v_date, v_taken, p_kind,
    left(coalesce(p_topic, ''), 500),
    least(greatest(coalesce(p_time_limit, 60), 10), 600),
    p_score, p_content_score, p_organization_score, p_language_score,
    left(coalesce(p_transcript, ''), 4000),
    left(coalesce(p_corrected, ''), 4000),
    left(coalesce(p_natural, ''), 4000),
    left(coalesce(p_good_points, ''), 4000),
    left(coalesce(p_fix_points, ''), 4000),
    left(coalesce(p_phrases, ''), 2000),
    p_read_aloud_accuracy)
  returning r.id into v_id;

  perform public._insert_mistakes(v_uid, v_date, 'topic', p_mistakes);

  -- 新しい 20 件だけ残す
  delete from public.topic_results r
   where r.user_id = v_uid
     and r.id not in (select r2.id from public.topic_results r2 where r2.user_id = v_uid
                       order by r2.created_at desc, r2.id desc limit 20);
  return v_id;
end;
$$;

-- p_timezone は使わないが、アプリは RPC に必ず付けて送るので受け取れるようにしておく
-- (PostgREST は送られた引数の名前で関数を選ぶため、無いと「関数が見つからない」になる)
create function public.set_topic_read_aloud(p_id bigint, p_accuracy integer, p_timezone text default 'Asia/Tokyo')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_accuracy is null or p_accuracy not between 0 and 100 then
    raise exception 'invalid read aloud accuracy' using errcode = '22023';
  end if;
  update public.topic_results r set read_aloud_accuracy = p_accuracy
   where r.id = p_id and r.user_id = auth.uid();   -- 本人の結果だけ
end;
$$;

create function public.save_mistakes(
  p_timezone text default 'Asia/Tokyo',
  p_source   text default 'diary',
  p_mistakes jsonb default '[]'::jsonb,
  p_taken_at timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_source is null or p_source not in ('diary', 'summary', 'topic') then
    raise exception 'invalid source' using errcode = '22023';
  end if;
  return public._insert_mistakes(v_uid, public._practice_date(p_taken_at, p_timezone), p_source, p_mistakes);
end;
$$;

-- 直近 30 日で多いミスの種類 (上位 3)。previous_count はその前の 30 日の回数
create function public.get_my_weak_points(p_timezone text default 'Asia/Tokyo')
returns table (type text, count integer, previous_count integer)
language sql
stable
security invoker
set search_path = public
as $$
  with t as (select public.app_today(coalesce(p_timezone, 'Asia/Tokyo')) as today)
  select m.type,
         count(*) filter (where m.entry_date > t.today - 30)::integer as count,
         count(*) filter (where m.entry_date <= t.today - 30 and m.entry_date > t.today - 60)::integer as previous_count
    from public.mistakes m, t
   where m.user_id = (select auth.uid())
   group by m.type
  having count(*) filter (where m.entry_date > t.today - 30) > 0
   order by 2 desc, m.type
   limit 3;
$$;

-- ------------------------------------------------------------
-- Web 用
-- ------------------------------------------------------------
create function public.get_my_topic_results(p_limit integer default 20)
returns table (
  id bigint, entry_date date, created_at timestamptz, kind text, topic text, time_limit_seconds integer,
  score integer, content_score integer, organization_score integer, language_score integer,
  transcript text, corrected text, natural_version text, good_points text, fix_points text, phrases text,
  read_aloud_accuracy integer)
language sql
stable
security invoker
set search_path = public
as $$
  select r.id, r.entry_date, r.created_at, r.kind, r.topic, r.time_limit_seconds,
         r.score, r.content_score, r.organization_score, r.language_score,
         r.transcript, r.corrected, r.natural_version, r.good_points, r.fix_points, r.phrases,
         r.read_aloud_accuracy
    from public.topic_results r
   where r.user_id = (select auth.uid())
   order by r.created_at desc, r.id desc
   limit least(greatest(coalesce(p_limit, 20), 1), 20);
$$;

-- 期間内 (p_days 日。1〜90) のミスの種類ごとの回数、その前の同じ長さの期間の回数、例 (新しい順に最大 5)。
-- ミスは 90 日分しか残さないので、前の期間が 90 日より前にかかるとき (p_days > 45) は previous_count を null にする
create function public.get_my_mistake_stats(p_days integer default 30)
returns table (type text, count integer, previous_count integer, examples jsonb)
language sql
stable
security invoker
set search_path = public
as $$
  with p as (
    select public.app_today('Asia/Tokyo') as today,
           least(greatest(coalesce(p_days, 30), 1), 90) as days
  ),
  mine as (
    select m.*, p.today, p.days from public.mistakes m, p
     where m.user_id = (select auth.uid())
  )
  select x.type,
         count(*) filter (where x.entry_date > x.today - x.days)::integer as count,
         case when x.days * 2 > 90 then null
              else count(*) filter (where x.entry_date <= x.today - x.days
                                      and x.entry_date > x.today - 2 * x.days)::integer
         end as previous_count,
         coalesce((
           select jsonb_agg(jsonb_build_object('wrong', e.wrong, 'fixed', e.fixed,
                                               'source', e.source, 'date', e.entry_date)
                            order by e.created_at desc, e.id desc)
             from (select * from mine e2
                    where e2.type = x.type and e2.entry_date > e2.today - e2.days
                    order by e2.created_at desc, e2.id desc limit 5) e
         ), '[]'::jsonb) as examples
    from mine x
   group by x.type, x.today, x.days
  having count(*) filter (where x.entry_date > x.today - x.days) > 0
      or (x.days * 2 <= 90
          and count(*) filter (where x.entry_date <= x.today - x.days and x.entry_date > x.today - 2 * x.days) > 0)
   order by 2 desc, 3 desc nulls last, x.type;
$$;

revoke all on function public.save_topic_result(text, text, text, integer, integer, integer, integer, integer,
  text, text, text, text, text, text, integer, jsonb, timestamptz) from public, anon;
revoke all on function public.set_topic_read_aloud(bigint, integer, text) from public, anon;
revoke all on function public.save_mistakes(text, text, jsonb, timestamptz) from public, anon;
revoke all on function public.get_my_topic_results(integer) from public, anon;
revoke all on function public.get_my_weak_points(text) from public, anon;
revoke all on function public.get_my_mistake_stats(integer) from public, anon;
grant execute on function public.save_topic_result(text, text, text, integer, integer, integer, integer, integer,
  text, text, text, text, text, text, integer, jsonb, timestamptz) to authenticated;
grant execute on function public.set_topic_read_aloud(bigint, integer, text) to authenticated;
grant execute on function public.save_mistakes(text, text, jsonb, timestamptz) to authenticated;
grant execute on function public.get_my_topic_results(integer) to authenticated;
grant execute on function public.get_my_weak_points(text) to authenticated;
grant execute on function public.get_my_mistake_stats(integer) to authenticated;
