-- ============================================================
-- 単語帳 (アプリの「Vocab」) を 1 回終えた日を、連続記録とカレンダーに数える
--   実行順: schema.sql → summary.sql → topic.sql → repeat.sql → vocab.sql
--   何度実行しても壊れない。単語帳そのもの (単語・復習の履歴) はアプリの端末の中だけ。
-- ============================================================

-- 「やった日」の種類 (schema.sql・topic.sql・repeat.sql・answer.sql と同じ 7 種類)
alter table public.activity_days drop constraint if exists activity_days_kind_check;
alter table public.activity_days add constraint activity_days_kind_check
  check (kind in ('diary', 'summary', 'topic', 'repeat', 'vocab', 'answer', 'karaoke'));

-- やった日カレンダー (schema.sql と同じ定義。vocab.sql だけ後から実行しても単語帳の列が出るように)
drop function if exists public.get_my_activity_days(date, date);
create function public.get_my_activity_days(p_from date, p_to date)
returns table (day date, diary boolean, summary boolean, topic boolean, repeat boolean, vocab boolean)
language sql
stable
security invoker
set search_path = public
as $$
  select a.day,
         bool_or(a.kind = 'diary')   as diary,
         bool_or(a.kind = 'summary') as summary,
         bool_or(a.kind = 'topic')   as topic,
         bool_or(a.kind = 'repeat')  as repeat,
         bool_or(a.kind = 'vocab')   as vocab
  from public.activity_days a
  where a.user_id = (select auth.uid())
    and a.day between p_from and least(p_to, p_from + 400)
  group by a.day
  order by a.day;
$$;
revoke all on function public.get_my_activity_days(date, date) from public, anon;
grant execute on function public.get_my_activity_days(date, date) to authenticated;

-- 1 回終えた → その日を「単語帳の日」にし、連続記録を進める
--   (リピーティングと同じ規則: 次の日なら +1、空いていれば 1、同じ日・過去の日なら変えない)
drop function if exists public.complete_vocab_session(text, timestamptz);
create function public.complete_vocab_session(p_timezone text default 'Asia/Tokyo', p_taken_at timestamptz default null)
returns table (streak integer, already_done boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_date date;
  v_row  public.streaks%rowtype;
  v_new  integer;
  v_done boolean;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  v_date := public._practice_date(p_taken_at, coalesce(p_timezone, 'Asia/Tokyo'));

  perform set_config('app.streak_source', 'vocab', true);
  insert into public.activity_days (user_id, day, kind) values (v_uid, v_date, 'vocab')
  on conflict do nothing;

  insert into public.streaks (user_id) values (v_uid)
  on conflict (user_id) do nothing;
  select * into v_row from public.streaks s where s.user_id = v_uid for update;

  v_done := v_row.last_study_date is not null and v_date <= v_row.last_study_date;
  if not v_done then
    if v_row.last_study_date = v_date - 1 then
      v_new := v_row.current_streak + 1;
    else
      v_new := 1;
    end if;
    update public.streaks s
       set current_streak = v_new,
           last_study_date = v_date,
           best_streak = greatest(s.best_streak, s.current_streak, v_new),
           updated_at = now()
     where s.user_id = v_uid;
  end if;

  perform set_config('app.streak_source', '', true);
  return query select s.current_streak, v_done from public.streaks s where s.user_id = v_uid;
end;
$$;
revoke all on function public.complete_vocab_session(text, timestamptz) from public, anon;
grant execute on function public.complete_vocab_session(text, timestamptz) to authenticated;
