-- ============================================================
-- 追加: 端末内の連続日数をクラウドに引き継ぐ関数 (Unityアプリのログイン時に1回使う)
-- Supabase の SQL Editor に貼り付けて Run (何度実行してもよい)。schema.sql を先に実行済みであること。
--
-- ルール (不正に伸ばせないための制限):
--   ・最後の記録日は「今日」か「昨日」だけ受け付ける (途切れた記録は引き継がない)
--   ・連続日数は 1〜3650
--   ・サーバーの有効な連続日数より大きいときだけ反映する (減らす方向には使えない)
--   ・すでにサーバーに「今日」の記録があって、端末の最後が「昨日」なら、今日ぶんを足して数える
-- ============================================================
create or replace function public.import_local_streak(
  p_streak    integer,
  p_last_date date,
  p_timezone  text default 'Asia/Tokyo'
)
returns table (streak integer, last_date date, imported boolean)
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
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  begin
    v_today := (now() at time zone p_timezone)::date;
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  if p_streak is null or p_streak < 1 or p_streak > 3650 then
    raise exception 'invalid streak' using errcode = '22023';
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
  -- サーバーには今日の記録があり、端末は昨日までだった場合: 今日ぶんを足す
  if v_row.last_study_date is not null and v_row.last_study_date > p_last_date then
    v_last := v_row.last_study_date;
    if v_last - p_last_date = 1 then
      v_cand := p_streak + 1;
    end if;
  end if;

  if v_cand > v_effective then
    update public.streaks s
       set current_streak = v_cand,
           last_study_date = v_last,
           updated_at = now()
     where s.user_id = v_uid;
    return query select v_cand, v_last, true;
  else
    return query select v_effective, v_row.last_study_date, false;
  end if;
end;
$$;

revoke all on function public.import_local_streak(integer, date, text) from public, anon;
grant execute on function public.import_local_streak(integer, date, text) to authenticated;
