-- Talk (アプリで 3D キャラクターの Lufka と英会話の練習) を 1 回したら、その日を連続記録に数える。
-- アプリは 1 回の会話で 3 回以上話したら complete_talk_session を呼ぶ。会話の中身は保存しない (端末の中だけ)。
-- その日を「Talk の日」(kind = 'talk') にして連続記録を進める (単語帳と同じ規則)。
-- 何度流しても同じ状態になる。schema.sql・summary.sql・topic.sql・repeat.sql・vocab.sql・answer.sql・karaoke.sql の後に流す。

-- 「やった日」の種類 (ほかの SQL と同じ 8 種類)
alter table public.activity_days drop constraint if exists activity_days_kind_check;
alter table public.activity_days add constraint activity_days_kind_check
  check (kind in ('diary', 'summary', 'topic', 'repeat', 'vocab', 'answer', 'karaoke', 'talk'));

-- 1 回分を数えて、連続記録を進める (次の日なら +1、空いていれば 1、同じ日・過去の日なら変えない)
drop function if exists public.complete_talk_session(text, timestamptz);
create function public.complete_talk_session(p_timezone text default 'Asia/Tokyo', p_taken_at timestamptz default null)
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

  perform set_config('app.streak_source', 'talk', true);
  insert into public.activity_days (user_id, day, kind) values (v_uid, v_date, 'talk')
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

revoke all on function public.complete_talk_session(text, timestamptz) from public, anon;
grant execute on function public.complete_talk_session(text, timestamptz) to authenticated;
