-- ============================================================
-- 追加: 要約練習 (Versant 対策) の採点結果
-- Supabase の SQL Editor に貼り付けて Run (何度実行してもよい。前の版を実行済みでも、そのまま上書きできる)。
--
--   save_summary_result      … アプリ: 採点結果を1件保存する
--   get_my_summary_results   … Web  : 自分の採点結果を新しい順に返す (点数の推移・内訳のグラフ用)
--
-- 点数は項目ごとに付ける: 内容 (50点) + 構成 (25点) + 文法・語彙 (25点) = 合計 (100点)。
-- 合計はアプリで計算し、サーバーでは内訳と合っているかを確かめる。
-- (項目別の採点を入れる前に保存した結果は、内訳が null になる)
--
-- 点数の推移を見るため、日記と違って古い結果も残す (1人あたり新しい 1000 件まで)。
-- テーブルは本人の行を「読む」ことだけ許可し、書き込みは関数経由だけにする。
-- ============================================================

create table if not exists public.summary_results (
  id                  bigint generated always as identity primary key,
  user_id             uuid not null default auth.uid() references auth.users (id) on delete cascade,
  entry_date          date not null,                       -- 利用者のタイムゾーンでの日付
  created_at          timestamptz not null default now(),
  video_id            text not null default '',
  video_title         text not null default '',
  time_limit_seconds  integer not null default 60,
  score               integer not null check (score between 0 and 100),   -- 合計
  transcript          text not null default '',             -- 話した要約
  reference_summary   text not null default '',             -- お手本の要約
  good_points         text not null default '',
  missed_points       text not null default '',
  language_feedback   text not null default '',
  improved_summary    text not null default ''
);

-- 項目ごとの点数 (前の版のテーブルにも追加する)
alter table public.summary_results
  add column if not exists content_score      integer check (content_score between 0 and 50),
  add column if not exists organization_score integer check (organization_score between 0 and 25),
  add column if not exists language_score     integer check (language_score between 0 and 25);

create index if not exists summary_results_user_created_idx
  on public.summary_results (user_id, created_at desc);

alter table public.summary_results enable row level security;

drop policy if exists "summary_results: read own" on public.summary_results;
create policy "summary_results: read own" on public.summary_results
  for select to authenticated
  using (user_id = (select auth.uid()));

revoke insert, update, delete on public.summary_results from anon, authenticated;

-- 引数や戻り値の形が変わると「同じ名前の別の関数」ができてしまうため、前の版を消してから作り直す
drop function if exists public.save_summary_result(text, text, text, integer, integer, text, text, text, text, text, text);
drop function if exists public.save_summary_result(text, text, text, integer, integer, integer, integer, integer, text, text, text, text, text, text);
drop function if exists public.save_summary_result(text, text, text, integer, integer, integer, integer, integer, text, text, text, text, text, text, timestamptz);
drop function if exists public.get_my_summary_results(text, integer);

-- ------------------------------------------------------------
-- 保存 (アプリ)
-- ------------------------------------------------------------
create function public.save_summary_result(
  p_timezone           text default 'Asia/Tokyo',
  p_video_id           text default '',
  p_video_title        text default '',
  p_time_limit         integer default 60,
  p_score              integer default 0,
  p_content_score      integer default null,
  p_organization_score integer default null,
  p_language_score     integer default null,
  p_transcript         text default '',
  p_reference          text default '',
  p_good_points        text default '',
  p_missed_points      text default '',
  p_language_feedback  text default '',
  p_improved           text default '',
  -- 練習した日時 (ログイン前に受けた結果を、後から送るときに使う)。無ければ今
  p_taken_at           timestamptz default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_taken timestamptz;
  v_id    bigint;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  -- 練習した日時: 未来や、古すぎる (30日より前) 日時は受け付けず、今の日時にする
  v_taken := coalesce(p_taken_at, now());
  if v_taken > now() + interval '5 minutes' or v_taken < now() - interval '30 days' then
    v_taken := now();
  end if;

  begin
    v_today := (v_taken at time zone p_timezone)::date;
  exception when others then
    raise exception 'invalid timezone: %', p_timezone using errcode = '22023';
  end;

  if p_score is null or p_score < 0 or p_score > 100 then
    raise exception 'invalid score' using errcode = '22023';
  end if;

  -- 内訳は「3つとも有る」か「3つとも無い」のどちらか。有るなら、範囲と合計を確かめる
  if num_nonnulls(p_content_score, p_organization_score, p_language_score) not in (0, 3) then
    raise exception 'score breakdown is incomplete' using errcode = '22023';
  end if;
  if p_content_score is not null then
    if p_content_score not between 0 and 50
       or p_organization_score not between 0 and 25
       or p_language_score not between 0 and 25 then
      raise exception 'invalid score breakdown' using errcode = '22023';
    end if;
    if p_content_score + p_organization_score + p_language_score <> p_score then
      raise exception 'score does not match the breakdown' using errcode = '22023';
    end if;
  end if;

  -- 連打や不具合で大量に保存されないよう、1日 100 件まで
  if (select count(*) from public.summary_results r
       where r.user_id = v_uid and r.entry_date = v_today) >= 100 then
    raise exception 'too many results today' using errcode = '54000';
  end if;

  insert into public.summary_results as r (
    user_id, entry_date, created_at, video_id, video_title, time_limit_seconds,
    score, content_score, organization_score, language_score,
    transcript, reference_summary, good_points, missed_points, language_feedback, improved_summary)
  values (
    v_uid, v_today, v_taken,
    left(coalesce(p_video_id, ''), 32),
    left(coalesce(p_video_title, ''), 300),
    least(greatest(coalesce(p_time_limit, 60), 10), 600),
    p_score, p_content_score, p_organization_score, p_language_score,
    left(coalesce(p_transcript, ''), 4000),
    left(coalesce(p_reference, ''), 4000),
    left(coalesce(p_good_points, ''), 4000),
    left(coalesce(p_missed_points, ''), 4000),
    left(coalesce(p_language_feedback, ''), 4000),
    left(coalesce(p_improved, ''), 4000))
  returning r.id into v_id;

  -- 新しい 1000 件だけ残す
  delete from public.summary_results r
   where r.user_id = v_uid
     and r.id not in (select r2.id from public.summary_results r2
                       where r2.user_id = v_uid
                       order by r2.created_at desc, r2.id desc
                       limit 1000);

  return v_id;
end;
$$;

revoke all on function public.save_summary_result(text, text, text, integer, integer, integer, integer, integer, text, text, text, text, text, text, timestamptz) from public, anon;
grant execute on function public.save_summary_result(text, text, text, integer, integer, integer, integer, integer, text, text, text, text, text, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 一覧 (Web)
-- ------------------------------------------------------------
create function public.get_my_summary_results(
  p_timezone text default 'Asia/Tokyo',   -- ほかの関数と呼び方をそろえるため (日付は保存時に決まっている)
  p_limit    integer default 200
)
returns table (
  id bigint, entry_date date, created_at timestamptz, video_id text, video_title text,
  time_limit_seconds integer, score integer,
  content_score integer, organization_score integer, language_score integer,
  transcript text, reference_summary text,
  good_points text, missed_points text, language_feedback text, improved_summary text)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.entry_date, r.created_at, r.video_id, r.video_title,
         r.time_limit_seconds, r.score,
         r.content_score, r.organization_score, r.language_score,
         r.transcript, r.reference_summary,
         r.good_points, r.missed_points, r.language_feedback, r.improved_summary
    from public.summary_results r
   where r.user_id = auth.uid()
   order by r.created_at desc, r.id desc
   limit least(greatest(coalesce(p_limit, 200), 1), 1000);
$$;

revoke all on function public.get_my_summary_results(text, integer) from public, anon;
grant execute on function public.get_my_summary_results(text, integer) to authenticated;
