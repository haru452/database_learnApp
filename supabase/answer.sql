-- 短い答えの練習 (Versant の Short Answer Questions): "What do you use to open a door?" → "a key"。
-- アプリは 1 回 (最大 20 問) を終えたら complete_short_answer_session を呼ぶ。
-- 問題・自分の答え・正解かを残し、その日を「短い答えの日」(kind = 'answer') にして連続記録を進める。
-- 何度流しても同じ状態になる。schema.sql・summary.sql・topic.sql・repeat.sql・vocab.sql の後に流す。

create table if not exists public.short_answer_results (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references auth.users (id) on delete cascade,
  taken_at  timestamptz not null default now(),
  question  text not null check (char_length(question) between 1 and 300),
  answers   text[] not null check (cardinality(answers) between 1 and 8),
  heard     text not null default '' check (char_length(heard) <= 200),
  correct   boolean not null
);
create index if not exists short_answer_results_user_time on public.short_answer_results (user_id, taken_at desc, id desc);

alter table public.short_answer_results enable row level security;
revoke all on public.short_answer_results from anon, authenticated;
grant select on public.short_answer_results to authenticated;
drop policy if exists "short_answer_results_select_own" on public.short_answer_results;
create policy "short_answer_results_select_own"
  on public.short_answer_results for select
  to authenticated
  using (user_id = auth.uid());

-- 「やった日」の種類 (schema.sql・topic.sql・repeat.sql・vocab.sql と同じ 6 種類)
alter table public.activity_days drop constraint if exists activity_days_kind_check;
alter table public.activity_days add constraint activity_days_kind_check
  check (kind in ('diary', 'summary', 'topic', 'repeat', 'vocab', 'answer'));

-- 1 回分を残して、連続記録を進める (単語帳と同じ規則: 次の日なら +1、空いていれば 1、同じ日・過去の日なら変えない)
-- p_items: [{"question":"...","answers":["key","keys"],"heard":"a key","correct":true}, ...]
drop function if exists public.complete_short_answer_session(jsonb, text, timestamptz);
create function public.complete_short_answer_session(p_items jsonb, p_timezone text default 'Asia/Tokyo',
                                                     p_taken_at timestamptz default null)
returns table (streak integer, already_done boolean, saved integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_date  date;
  v_at    timestamptz := least(coalesce(p_taken_at, now()), now());
  v_row   public.streaks%rowtype;
  v_new   integer;
  v_done  boolean;
  v_saved integer;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > 20 then
    raise exception 'too many items (max 20)' using errcode = '22023';
  end if;

  insert into public.short_answer_results (user_id, taken_at, question, answers, heard, correct)
  select v_uid, v_at, btrim(e.item ->> 'question'), a.list,
         left(coalesce(e.item ->> 'heard', ''), 200),
         coalesce((e.item ->> 'correct')::boolean, false)
  from jsonb_array_elements(p_items) as e(item)
  cross join lateral (
    select array(
      select left(btrim(x), 60)
      from jsonb_array_elements_text(
             case when jsonb_typeof(e.item -> 'answers') = 'array' then e.item -> 'answers' else '[]'::jsonb end) as x
      where btrim(x) <> ''
      limit 8) as list
  ) as a
  where jsonb_typeof(e.item) = 'object'
    and char_length(btrim(coalesce(e.item ->> 'question', ''))) between 1 and 300
    and cardinality(a.list) > 0
    and coalesce(e.item ->> 'correct', '') in ('true', 'false');
  get diagnostics v_saved = row_count;
  if v_saved = 0 then
    raise exception 'no valid items' using errcode = '22023';
  end if;

  v_date := public._practice_date(v_at, coalesce(p_timezone, 'Asia/Tokyo'));
  perform set_config('app.streak_source', 'answer', true);
  insert into public.activity_days (user_id, day, kind) values (v_uid, v_date, 'answer')
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
  return query select s.current_streak, v_done, v_saved from public.streaks s where s.user_id = v_uid;
end;
$$;
revoke all on function public.complete_short_answer_session(jsonb, text, timestamptz) from public, anon;
grant execute on function public.complete_short_answer_session(jsonb, text, timestamptz) to authenticated;
