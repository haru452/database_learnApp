-- Claude (claude.ai) との英語の会話で直してもらったミスを保存し、その日を連続記録に数える。
-- 流れ: Claude が Google Drive の claude-english-mistakes フォルダに YYYY-MM-DD_chat.json を置く
--       → Windows のスクリプト (tools/chat-sync) がそのファイルを読んで save_chat_day を呼ぶ。
-- パソコンが切れていた日の分は、あとでまとめて送られる。そのため:
--   ・日付はファイルの日付 (p_date) を使う。未来の日と、90 日より前の日は受け付けない。
--   ・同じファイル (p_file_key) を 2 回送っても、2 回目は何もしない (chat_uploads で覚えている)。
--   ・過去の日を足して連続がつながったら、連続記録を伸ばす (減らす方向には変えない)。
-- ミスは「よくあるミス」に source = 'chat' で入る。やった日は kind = 'chat' (Talk と同じく、連続記録だけに数える)。
-- 何度流しても同じ状態になる。schema.sql 〜 talk.sql の後に流す。

-- 「やった日」の種類 (ほかの SQL と同じ 9 種類)
alter table public.activity_days drop constraint if exists activity_days_kind_check;
alter table public.activity_days add constraint activity_days_kind_check
  check (kind in ('diary', 'summary', 'topic', 'repeat', 'vocab', 'answer', 'karaoke', 'talk', 'chat'));

-- ミスの出どころに chat を足す (topic.sql の表の定義と同じ)
alter table public.mistakes drop constraint if exists mistakes_source_check;
alter table public.mistakes add constraint mistakes_source_check
  check (source in ('diary', 'summary', 'topic', 'chat'));

-- 送ったファイルの記録 (同じファイルを 2 回数えないため)
create table if not exists public.chat_uploads (
  user_id       uuid not null references auth.users (id) on delete cascade,
  file_key      text not null check (char_length(file_key) between 1 and 200),
  entry_date    date not null,
  mistake_count integer not null default 0,
  created_at    timestamptz not null default now(),
  primary key (user_id, file_key)
);
alter table public.chat_uploads enable row level security;
drop policy if exists "chat_uploads: read own" on public.chat_uploads;
create policy "chat_uploads: read own" on public.chat_uploads
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.chat_uploads from anon, authenticated;
grant select on public.chat_uploads to authenticated;

-- 1 日分 (1 ファイル) を保存する
drop function if exists public.save_chat_day(text, date, jsonb, text);
create function public.save_chat_day(
  p_file_key text,
  p_date     date,
  p_mistakes jsonb default '[]'::jsonb,
  p_timezone text default 'Asia/Tokyo'
)
returns table (saved integer, already_sent boolean, streak integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_key   text := trim(coalesce(p_file_key, ''));
  v_saved integer := 0;
  v_row   public.streaks%rowtype;
  v_run   integer;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if v_key = '' or char_length(v_key) > 200 then
    raise exception 'invalid file key' using errcode = '22023';
  end if;
  begin
    v_today := public.app_today(coalesce(p_timezone, 'Asia/Tokyo'));
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;
  -- 3 時までは前の日として扱うので、ファイルの日付が「今日 + 1」までは受け付ける
  if p_date is null or p_date > v_today + 1 or p_date < v_today - 90 then
    raise exception 'invalid date: %', p_date using errcode = '22023';
  end if;

  -- もう送ったファイルなら何もしない
  insert into public.chat_uploads (user_id, file_key, entry_date) values (v_uid, v_key, p_date)
  on conflict do nothing;
  if not found then
    return query select 0, true, coalesce((select s.current_streak from public.streaks s where s.user_id = v_uid), 0);
    return;
  end if;

  v_saved := public._insert_mistakes(v_uid, p_date, 'chat', p_mistakes);
  update public.chat_uploads u set mistake_count = v_saved where u.user_id = v_uid and u.file_key = v_key;

  perform set_config('app.streak_source', 'chat', true);
  insert into public.activity_days (user_id, day, kind) values (v_uid, p_date, 'chat')
  on conflict do nothing;

  insert into public.streaks (user_id) values (v_uid)
  on conflict (user_id) do nothing;
  select * into v_row from public.streaks s where s.user_id = v_uid for update;

  if v_row.last_study_date is null or p_date > v_row.last_study_date then
    -- いちばん新しい日: Talk と同じ (次の日なら +1、空いていれば 1)
    update public.streaks s
       set current_streak = case when v_row.last_study_date = p_date - 1 then v_row.current_streak + 1 else 1 end,
           last_study_date = p_date,
           best_streak = greatest(s.best_streak, s.current_streak,
                                  case when v_row.last_study_date = p_date - 1 then v_row.current_streak + 1 else 1 end),
           updated_at = now()
     where s.user_id = v_uid;
  else
    -- 過去の日: やった日を最後の日からさかのぼって数え、今の連続日数より長ければ伸ばす
    with d as (
      select distinct a.day from public.activity_days a
       where a.user_id = v_uid and a.day <= v_row.last_study_date
    ), g as (
      select d.day, d.day - (row_number() over (order by d.day))::integer as grp from d
    )
    select count(*) into v_run from g
     where g.grp = (select g2.grp from g g2 where g2.day = v_row.last_study_date);
    if v_run > v_row.current_streak then
      update public.streaks s
         set current_streak = v_run,
             best_streak = greatest(s.best_streak, v_run),
             updated_at = now()
       where s.user_id = v_uid;
    end if;
  end if;

  perform set_config('app.streak_source', '', true);
  return query select v_saved, false, (select s.current_streak from public.streaks s where s.user_id = v_uid);
end;
$$;

revoke all on function public.save_chat_day(text, date, jsonb, text) from public, anon;
grant execute on function public.save_chat_day(text, date, jsonb, text) to authenticated;
