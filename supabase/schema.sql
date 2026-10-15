-- ============================================================
-- 連続学習記録 (ストリーク) と、日記(直近7日分)用のテーブルと関数
-- Supabase ダッシュボードの「SQL Editor」に貼り付けて、Run で実行する (何度実行してもよい。データは消えない)
-- ============================================================

-- 1) テーブル: ユーザーごとに1行
create table if not exists public.streaks (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  current_streak  integer not null default 0 check (current_streak >= 0),
  last_study_date date,
  updated_at      timestamptz not null default now()
);
-- 最長記録 (Best)。あとから追加した列なので、既存のテーブルにも足す
alter table public.streaks add column if not exists best_streak integer not null default 0 check (best_streak >= 0);

-- 2) RLS: 本人の行だけ読める。書き込みは、下の complete_study() 経由のみ
--    (クライアントから streak を直接書き換えて不正をされないようにする)
alter table public.streaks enable row level security;

drop policy if exists "streaks_select_own" on public.streaks;
create policy "streaks_select_own"
  on public.streaks for select
  to authenticated
  using ((select auth.uid()) = user_id);

revoke all on public.streaks from anon, authenticated;
grant select on public.streaks to authenticated;

-- 2b) やった日の記録 (Web の「やった日カレンダー」用。ずっと残る。1日に diary / summary の2行まで)
--     日記: complete_study() と import_local_streak() が記録する
--     要約練習: summary.sql のトリガーが記録する
create table if not exists public.activity_days (
  user_id uuid not null references auth.users (id) on delete cascade,
  day     date not null,
  kind    text not null check (kind in ('diary', 'summary')),
  primary key (user_id, day, kind)
);
alter table public.activity_days enable row level security;

drop policy if exists "activity_days_select_own" on public.activity_days;
create policy "activity_days_select_own"
  on public.activity_days for select
  to authenticated
  using ((select auth.uid()) = user_id);

revoke all on public.activity_days from anon, authenticated;
grant select on public.activity_days to authenticated;

-- 連続記録が「まとめて」増えたとき (端末の記録の引き継ぎ = import_local_streak) は、
-- その連続期間の日を日記の日として記録する。
-- complete_study() と要約練習は自分で1日分を記録するので、app.streak_source を付けてここを飛ばす。
create or replace function public.activity_days_from_streak()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('app.streak_source', true), '') <> '' then
    return new;
  end if;
  if new.last_study_date is not null and new.current_streak > 0 then
    insert into public.activity_days (user_id, day, kind)
    select new.user_id, d::date, 'diary'
    from generate_series(new.last_study_date - (least(new.current_streak, 3650) - 1),
                         new.last_study_date, interval '1 day') as d
    on conflict do nothing;
  end if;
  return new;
end;
$$;
revoke all on function public.activity_days_from_streak() from public, anon, authenticated;

drop trigger if exists activity_days_from_streak on public.streaks;
create trigger activity_days_from_streak
  after insert or update of current_streak, last_study_date on public.streaks
  for each row execute function public.activity_days_from_streak();

-- ============================================================
-- 3) ストリーク用の関数
--    ※ 返す列を変えるため、いったん消して作り直す (テーブルのデータは消えない)
-- ============================================================
-- 「1日の切り替わり時刻」。ここを変えると、記録が途切れる時刻が変わる。
--   3 → 夜中の 3:00 までは「前の日」として扱う (深夜 1 時に書いた日記は、前の日の分になる)
--   0 → 普通の 0:00 切り替え
--   ※ アプリ側 (Unity の Day Boundary Hour) と Worker (DAY_START_HOUR) も同じ値にそろえること
create or replace function public.app_today(p_timezone text)
returns date
language sql
stable
as $$
  select ((now() at time zone p_timezone) - interval '3 hours')::date
$$;

drop function if exists public.complete_study(text);
drop function if exists public.get_my_streak(text);
drop function if exists public.import_local_streak(integer, date, text);
drop function if exists public.import_local_streak(integer, date, text, integer);

-- 「学習完了」
--   ・最後の学習日が「昨日」→ +1 / 「今日」→ そのまま (already_done = true) / 2日以上空き・初回 → 1
--   ・best_streak (最長記録) も更新する
--   「今日」は、サーバーの時刻を p_timezone で換算して決める (端末の時計をいじっても変えられない)
create function public.complete_study(p_timezone text default 'Asia/Tokyo')
returns table (streak integer, last_date date, already_done boolean, best_streak integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_row   public.streaks%rowtype;
  v_new   integer;
  v_best  integer;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  begin
    v_today := public.app_today(p_timezone);
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  -- 今日を「日記をやった日」として記録する (カレンダー用)
  perform set_config('app.streak_source', 'complete', true);
  insert into public.activity_days (user_id, day, kind) values (v_uid, v_today, 'diary')
  on conflict do nothing;

  -- 初回は行を作る。同時に押されても、行ロックで1つずつ処理される
  insert into public.streaks (user_id) values (v_uid)
  on conflict (user_id) do nothing;

  select * into v_row from public.streaks s where s.user_id = v_uid for update;

  -- 今日すでに完了している (タイムゾーンを変えて日付が戻った場合も、ここに入る)
  if v_row.last_study_date is not null and v_row.last_study_date >= v_today then
    return query select v_row.current_streak, v_row.last_study_date, true,
                        greatest(v_row.best_streak, v_row.current_streak);
    return;
  end if;

  if v_row.last_study_date = v_today - 1 then
    v_new := v_row.current_streak + 1;
  else
    v_new := 1;
  end if;
  v_best := greatest(v_row.best_streak, v_row.current_streak, v_new);

  update public.streaks s
     set current_streak = v_new,
         last_study_date = v_today,
         best_streak = v_best,
         updated_at = now()
   where s.user_id = v_uid;

  return query select v_new, v_today, false, v_best;
end;
$$;

-- 表示用: 「いま有効な」連続日数。最後の学習が一昨日以前なら、途切れているので 0
create function public.get_my_streak(p_timezone text default 'Asia/Tokyo')
returns table (streak integer, last_date date, studied_today boolean, best_streak integer)
language plpgsql
stable
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_row   public.streaks%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  begin
    v_today := public.app_today(p_timezone);
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  select * into v_row from public.streaks s where s.user_id = v_uid;

  if not found then
    return query select 0, null::date, false, 0;
    return;
  end if;

  return query select
    case when v_row.last_study_date >= v_today - 1 then v_row.current_streak else 0 end,
    v_row.last_study_date,
    (v_row.last_study_date >= v_today),
    greatest(v_row.best_streak, v_row.current_streak);
end;
$$;

-- 端末内の連続日数と最長記録を、クラウドに引き継ぐ (Unityアプリのログイン後に1回)
-- ルール (不正に伸ばせないための制限):
--   ・最後の記録日は「今日」か「昨日」だけ受け付ける / 連続日数・Best は 0〜3650
--   ・サーバーの有効な連続日数より大きいときだけ、連続日数を反映する (減らす方向には使えない)
--   ・Best は、大きくなる方向にだけ更新する
--   ・サーバーに「今日」の記録があって、端末の最後が「昨日」なら、今日ぶんを足して数える
create function public.import_local_streak(
  p_streak    integer,
  p_last_date date,
  p_timezone  text default 'Asia/Tokyo',
  p_best      integer default null
)
returns table (streak integer, last_date date, imported boolean, best_streak integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid       uuid := auth.uid();
  v_today     date;
  v_row       public.streaks%rowtype;
  v_effective integer := 0;
  v_last      date;
  v_cand      integer;
  v_best      integer;
  v_applied   boolean := false;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  begin
    v_today := public.app_today(p_timezone);
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  if p_streak is null or p_streak < 1 or p_streak > 3650 then
    raise exception 'invalid streak' using errcode = '22023';
  end if;
  if p_best is not null and (p_best < 0 or p_best > 3650) then
    raise exception 'invalid best' using errcode = '22023';
  end if;
  if p_last_date is null or p_last_date > v_today or p_last_date < v_today - 1 then
    raise exception 'invalid last date' using errcode = '22023';
  end if;

  insert into public.streaks (user_id) values (v_uid)
  on conflict (user_id) do nothing;

  select * into v_row from public.streaks s where s.user_id = v_uid for update;

  if v_row.last_study_date is not null and v_row.last_study_date >= v_today - 1 then
    v_effective := v_row.current_streak;
  end if;

  v_last := p_last_date;
  v_cand := p_streak;
  if v_row.last_study_date is not null and v_row.last_study_date > p_last_date then
    v_last := v_row.last_study_date;
    if v_last - p_last_date = 1 then
      v_cand := p_streak + 1;
    end if;
  end if;

  v_best := greatest(v_row.best_streak, v_row.current_streak, coalesce(p_best, 0));

  if v_cand > v_effective then
    v_applied := true;
    v_best := greatest(v_best, v_cand);
    update public.streaks s
       set current_streak = v_cand,
           last_study_date = v_last,
           best_streak = v_best,
           updated_at = now()
     where s.user_id = v_uid;
    return query select v_cand, v_last, true, v_best;
  else
    if v_best > v_row.best_streak then
      update public.streaks s set best_streak = v_best, updated_at = now() where s.user_id = v_uid;
    end if;
    return query select v_effective, v_row.last_study_date, false, v_best;
  end if;
end;
$$;

-- ============================================================
-- 4) 日記 (直近7日分だけ保存)
--    ・今日を含む7日分より古いものは、保存・取得のたびに自動で消える
--    ・1人あたり最大100件 (超えたら古い順に消える)
--    ・クライアントから直接は書けない。保存は save_diary_entry() 経由のみ
-- ============================================================
create table if not exists public.diary_entries (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users (id) on delete cascade,
  entry_date     date not null,
  original_text  text not null check (char_length(original_text)  between 1 and 20000),
  corrected_text text not null check (char_length(corrected_text) between 1 and 20000),
  explanation    text not null default '' check (char_length(explanation) <= 20000),
  engine         text not null default '' check (char_length(engine) <= 40),
  created_at     timestamptz not null default now()
);

create index if not exists diary_entries_user_date_idx
  on public.diary_entries (user_id, entry_date desc, id desc);

alter table public.diary_entries enable row level security;

drop policy if exists "diary_select_own" on public.diary_entries;
create policy "diary_select_own"
  on public.diary_entries for select
  to authenticated
  using ((select auth.uid()) = user_id);

revoke all on public.diary_entries from anon, authenticated;
grant select on public.diary_entries to authenticated;

drop function if exists public.save_diary_entry(text, text, text, text, text);
drop function if exists public.get_my_diary(text);

create function public.save_diary_entry(
  p_original    text,
  p_corrected   text,
  p_explanation text default '',
  p_engine      text default '',
  p_timezone    text default 'Asia/Tokyo'
)
returns table (id bigint, entry_date date)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_id    bigint;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  begin
    v_today := public.app_today(p_timezone);
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  if coalesce(btrim(p_original), '') = '' or coalesce(btrim(p_corrected), '') = '' then
    raise exception 'empty text' using errcode = '22023';
  end if;
  if char_length(p_original) > 20000 or char_length(p_corrected) > 20000
     or char_length(coalesce(p_explanation, '')) > 20000 then
    raise exception 'text too long' using errcode = '22023';
  end if;

  insert into public.diary_entries (user_id, entry_date, original_text, corrected_text, explanation, engine)
  values (v_uid, v_today, p_original, p_corrected, coalesce(p_explanation, ''), left(coalesce(p_engine, ''), 40))
  returning diary_entries.id into v_id;

  -- 今日を含む7日より古いものを消す
  delete from public.diary_entries d
   where d.user_id = v_uid and d.entry_date < v_today - 6;

  -- 件数の上限 (新しい100件だけ残す)
  delete from public.diary_entries d
   where d.user_id = v_uid
     and d.id not in (
       select x.id from public.diary_entries x
        where x.user_id = v_uid
        order by x.created_at desc, x.id desc
        limit 100);

  return query select v_id, v_today;
end;
$$;

create function public.get_my_diary(p_timezone text default 'Asia/Tokyo')
returns table (
  id bigint, entry_date date, original_text text, corrected_text text,
  explanation text, engine text, created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  begin
    v_today := public.app_today(p_timezone);
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  -- 古いものは、見るときにも消しておく
  delete from public.diary_entries d
   where d.user_id = v_uid and d.entry_date < v_today - 6;

  return query
    select e.id, e.entry_date, e.original_text, e.corrected_text, e.explanation, e.engine, e.created_at
      from public.diary_entries e
     where e.user_id = v_uid and e.entry_date >= v_today - 6
     order by e.created_at desc, e.id desc;
end;
$$;

-- ============================================================
-- 4b) やった日カレンダー (Web 用)
-- ============================================================
drop function if exists public.get_my_activity_days(date, date);

-- 期間内のやった日 (1日1行。日記 / 要約練習をやったか)。一度に読むのは約1年分まで
create function public.get_my_activity_days(p_from date, p_to date)
returns table (day date, diary boolean, summary boolean)
language sql
stable
security invoker
set search_path = public
as $$
  select a.day,
         bool_or(a.kind = 'diary')   as diary,
         bool_or(a.kind = 'summary') as summary
  from public.activity_days a
  where a.user_id = (select auth.uid())
    and a.day between p_from and least(p_to, p_from + 400)
  group by a.day
  order by a.day;
$$;

-- いまある記録を取り込む (何度実行しても重複しない):
--   いまの連続期間 (要約練習を連続記録に数える前の期間なので、すべて日記の日) と、保存されている日記の日
insert into public.activity_days (user_id, day, kind)
select s.user_id, d::date, 'diary'
from public.streaks s
cross join lateral generate_series(s.last_study_date - (least(s.current_streak, 3650) - 1),
                                   s.last_study_date, interval '1 day') as d
where s.last_study_date is not null and s.current_streak > 0
  and not exists (select 1 from public.activity_days a where a.user_id = s.user_id)
on conflict do nothing;

insert into public.activity_days (user_id, day, kind)
select distinct e.user_id, e.entry_date, 'diary'
from public.diary_entries e
on conflict do nothing;

-- ============================================================
-- 5) 関数を呼べるのは、ログイン済みのユーザーだけ
-- ============================================================
revoke all on function public.complete_study(text)                          from public, anon;
revoke all on function public.get_my_streak(text)                           from public, anon;
revoke all on function public.import_local_streak(integer, date, text, integer) from public, anon;
revoke all on function public.save_diary_entry(text, text, text, text, text) from public, anon;
revoke all on function public.get_my_diary(text)                            from public, anon;
grant execute on function public.complete_study(text)                          to authenticated;
grant execute on function public.get_my_streak(text)                           to authenticated;
grant execute on function public.import_local_streak(integer, date, text, integer) to authenticated;
grant execute on function public.save_diary_entry(text, text, text, text, text) to authenticated;
grant execute on function public.get_my_diary(text)                            to authenticated;
revoke all on function public.get_my_activity_days(date, date)                 from public, anon;
grant execute on function public.get_my_activity_days(date, date)              to authenticated;
