-- カラオケ (洋楽を歌って、うまく発音できなかった単語を Gemini が見つける)。
-- アプリは 1 曲 (途中で止めてもよい) を採点したら complete_karaoke_session を呼ぶ。
-- 曲・点数・行ごとの赤い単語を残し、その日を「カラオケの日」(kind = 'karaoke') にして連続記録を進める。
-- 何度流しても同じ状態になる。answer.sql の後に流す。

create table if not exists public.karaoke_results (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references auth.users (id) on delete cascade,
  taken_at  timestamptz not null default now(),
  title     text not null check (char_length(title) between 1 and 200),
  artist    text not null default '' check (char_length(artist) <= 200),
  video_id  text not null default '' check (char_length(video_id) <= 20),
  score     integer not null check (score between 0 and 100),
  items     jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array')
);
-- Gemini のアドバイス (Web で見られるように)。前からある表にも足す
alter table public.karaoke_results add column if not exists advice text not null default '';
alter table public.karaoke_results drop constraint if exists karaoke_results_advice_check;
alter table public.karaoke_results add constraint karaoke_results_advice_check check (char_length(advice) <= 2000);

create index if not exists karaoke_results_user_time on public.karaoke_results (user_id, taken_at desc, id desc);

alter table public.karaoke_results enable row level security;
revoke all on public.karaoke_results from anon, authenticated;
grant select on public.karaoke_results to authenticated;
drop policy if exists "karaoke_results_select_own" on public.karaoke_results;
create policy "karaoke_results_select_own"
  on public.karaoke_results for select
  to authenticated
  using (user_id = auth.uid());

-- 「やった日」の種類 (schema.sql・topic.sql・repeat.sql・vocab.sql・answer.sql と同じ 7 種類)
alter table public.activity_days drop constraint if exists activity_days_kind_check;
alter table public.activity_days add constraint activity_days_kind_check
  check (kind in ('diary', 'summary', 'topic', 'repeat', 'vocab', 'answer', 'karaoke', 'talk'));

-- 1 曲分を残して、連続記録を進める (短い答えと同じ規則: 次の日なら +1、空いていれば 1、同じ日・過去の日なら変えない)
-- p_items: [{"line":0,"text":"I want it that way","words":[{"word":"that","sound":"th"}]}, ...] (赤い単語がある行だけ。最大 200 行)
-- p_advice: Gemini のアドバイス (2000 文字まで残す)
drop function if exists public.complete_karaoke_session(text, text, text, integer, jsonb, text, timestamptz);
drop function if exists public.complete_karaoke_session(text, text, text, integer, jsonb, text, timestamptz, text);
create function public.complete_karaoke_session(p_title text, p_artist text, p_video_id text, p_score integer,
                                                p_items jsonb, p_timezone text default 'Asia/Tokyo',
                                                p_taken_at timestamptz default null, p_advice text default '')
returns table (streak integer, already_done boolean)
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
  v_items jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 200 or p_score is null or p_score not between 0 and 100 then
    raise exception 'invalid title or score' using errcode = '22023';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > 200 then
    raise exception 'too many lines (max 200)' using errcode = '22023';
  end if;

  -- 形の合う行だけ残す (行番号・文・赤い単語 [最大 30 語、単語は 40 文字まで])
  select coalesce(jsonb_agg(jsonb_build_object(
           'line', (e.item ->> 'line')::integer,
           'text', left(coalesce(e.item ->> 'text', ''), 300),
           'words', w.list)), '[]'::jsonb)
    into v_items
  from jsonb_array_elements(p_items) as e(item)
  cross join lateral (
    select coalesce(jsonb_agg(jsonb_build_object('word', left(x ->> 'word', 40), 'sound', left(coalesce(x ->> 'sound', ''), 20))), '[]'::jsonb) as list
    from (select x from jsonb_array_elements(
            case when jsonb_typeof(e.item -> 'words') = 'array' then e.item -> 'words' else '[]'::jsonb end) as x
          where jsonb_typeof(x) = 'object' and btrim(coalesce(x ->> 'word', '')) <> ''
          limit 30) as words
  ) as w
  where jsonb_typeof(e.item) = 'object'
    and coalesce(e.item ->> 'line', '') ~ '^[0-9]{1,4}$'
    and jsonb_array_length(w.list) > 0;

  insert into public.karaoke_results (user_id, taken_at, title, artist, video_id, score, items, advice)
  values (v_uid, v_at, btrim(p_title), left(btrim(coalesce(p_artist, '')), 200), left(coalesce(p_video_id, ''), 20),
          p_score, v_items, left(btrim(coalesce(p_advice, '')), 2000));

  v_date := public._practice_date(v_at, coalesce(p_timezone, 'Asia/Tokyo'));
  perform set_config('app.streak_source', 'karaoke', true);
  insert into public.activity_days (user_id, day, kind) values (v_uid, v_date, 'karaoke')
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
revoke all on function public.complete_karaoke_session(text, text, text, integer, jsonb, text, timestamptz, text) from public, anon;
grant execute on function public.complete_karaoke_session(text, text, text, integer, jsonb, text, timestamptz, text) to authenticated;
