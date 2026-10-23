-- 週の連続 (月曜〜日曜。1 週間に 1 日でも練習した週が、今週・先週から何週続いているか)
-- schema.sql / topic.sql / repeat.sql の後に、Supabase の SQL Editor で 1 回実行する (何度実行してもよい)。
-- 数えるもとは activity_days (日記・要約・お題・リピーティング・シャドーイングをやった日。日は夜 3 時区切り)。

drop function if exists public._week_streak(uuid, date);
drop function if exists public.get_my_week_streak(text);

-- p_today の週 (月曜始まり) から数える。今週がまだなら先週から数え、this_week_done = false。
-- 先週も今週も無ければ 0。p_today より後の日は数えない。
create function public._week_streak(p_user uuid, p_today date)
returns table (weeks integer, this_week_done boolean)
language plpgsql
stable
set search_path = public
as $$
declare
  v_this  date := p_today - (extract(isodow from p_today)::integer - 1);
  v_week  date;
  v_n     integer := 0;
  v_done  boolean;
begin
  v_done := exists (select 1 from public.activity_days a
                     where a.user_id = p_user and a.day between v_this and p_today);
  v_week := case when v_done then v_this else v_this - 7 end;
  while exists (select 1 from public.activity_days a
                 where a.user_id = p_user and a.day >= v_week and a.day < v_week + 7 and a.day <= p_today) loop
    v_n := v_n + 1;
    v_week := v_week - 7;
  end loop;
  return query select v_n, v_done;
end;
$$;

create function public.get_my_week_streak(p_timezone text default 'Asia/Tokyo')
returns table (weeks integer, this_week_done boolean)
language plpgsql
stable
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
    v_today := public.app_today(coalesce(p_timezone, 'Asia/Tokyo'));
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;
  return query select * from public._week_streak(v_uid, v_today);
end;
$$;

revoke all on function public._week_streak(uuid, date) from public, anon, authenticated;
revoke all on function public.get_my_week_streak(text) from public, anon;
grant execute on function public.get_my_week_streak(text) to authenticated;
