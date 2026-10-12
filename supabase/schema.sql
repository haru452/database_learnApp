-- ============================================================
-- 連続学習記録 (ストリーク) 用のテーブルと関数
-- Supabase ダッシュボードの「SQL Editor」に貼り付けて、Run で実行する (何度実行してもよい)
-- ============================================================

-- 1) テーブル: ユーザーごとに1行
create table if not exists public.streaks (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  current_streak  integer not null default 0 check (current_streak >= 0),
  last_study_date date,
  updated_at      timestamptz not null default now()
);

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

-- 3) 「学習完了」ボタン用の関数
--    ・最後の学習日が「昨日」→ +1
--    ・最後の学習日が「今日」→ そのまま (already_done = true)
--    ・2日以上空いている / 初回 → 1 にリセット
--    ・last_study_date を「今日」に更新
--    「今日」は、サーバーの時刻を p_timezone で換算して決める (端末の時計をいじっても変えられない)
create or replace function public.complete_study(p_timezone text default 'Asia/Tokyo')
returns table (streak integer, last_date date, already_done boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_row   public.streaks%rowtype;
  v_new   integer;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  begin
    v_today := (now() at time zone p_timezone)::date;
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  -- 初回は行を作る。同時に押されても、行ロックで1つずつ処理される
  insert into public.streaks (user_id) values (v_uid)
  on conflict (user_id) do nothing;

  select * into v_row from public.streaks s where s.user_id = v_uid for update;

  -- 今日すでに完了している (タイムゾーンを変えて日付が戻った場合も、ここに入る)
  if v_row.last_study_date is not null and v_row.last_study_date >= v_today then
    return query select v_row.current_streak, v_row.last_study_date, true;
    return;
  end if;

  if v_row.last_study_date = v_today - 1 then
    v_new := v_row.current_streak + 1;
  else
    v_new := 1;
  end if;

  update public.streaks s
     set current_streak = v_new,
         last_study_date = v_today,
         updated_at = now()
   where s.user_id = v_uid;

  return query select v_new, v_today, false;
end;
$$;

-- 4) 表示用の関数: 「いま有効な」連続日数を返す
--    最後の学習が一昨日以前なら、すでに途切れているので 0 を返す
--    (テーブルの値は、次に学習するまで古いままなので、そのまま表示すると誤解を招く)
create or replace function public.get_my_streak(p_timezone text default 'Asia/Tokyo')
returns table (streak integer, last_date date, studied_today boolean)
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
    v_today := (now() at time zone p_timezone)::date;
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  select * into v_row from public.streaks s where s.user_id = v_uid;

  if not found then
    return query select 0, null::date, false;
    return;
  end if;

  return query select
    case when v_row.last_study_date >= v_today - 1 then v_row.current_streak else 0 end,
    v_row.last_study_date,
    (v_row.last_study_date >= v_today);
end;
$$;

-- 5) 関数を呼べるのは、ログイン済みのユーザーだけ
revoke all on function public.complete_study(text) from public, anon;
revoke all on function public.get_my_streak(text)  from public, anon;
grant execute on function public.complete_study(text) to authenticated;
grant execute on function public.get_my_streak(text)  to authenticated;
