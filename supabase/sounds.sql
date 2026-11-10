-- ============================================================
-- 苦手な発音 (発音チェックの判定 + 言えなかった単語からの推測)
--   実行順: schema.sql → summary.sql → topic.sql → repeat.sql → sounds.sql
--   何度実行しても壊れない。連続記録・カレンダーには数えない。
-- ============================================================

create table if not exists public.pronunciation_issues (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  entry_date  date not null,                          -- 練習した日 (夜 3 時区切り)
  created_at  timestamptz not null default now(),
  sound       text not null check (sound in ('th', 'r_l', 'v_b', 'f_h', 's_sh', 'vowel', 'long_short',
                                             'final_consonant', 'extra_vowel', 'stress', 'other')),
  label       text not null default '' check (char_length(label) <= 30),   -- other のときのそろえた名前
  weight      integer not null check (weight in (1, 3)),                     -- 3 = Gemini の判定、1 = 推測
  word        text not null default '' check (char_length(word) <= 40),
  source      text not null check (source in ('check', 'read_aloud', 'repeat', 'karaoke')),
  check ((sound = 'other') = (label <> ''))
);
-- 前に流した表にもカラオケを足す (表が先にあると create table の決まりは変わらないため)
alter table public.pronunciation_issues drop constraint if exists pronunciation_issues_source_check;
alter table public.pronunciation_issues add constraint pronunciation_issues_source_check
  check (source in ('check', 'read_aloud', 'repeat', 'karaoke'));
create index if not exists pronunciation_issues_user_date_idx
  on public.pronunciation_issues (user_id, entry_date desc, id desc);

alter table public.pronunciation_issues enable row level security;
revoke all on public.pronunciation_issues from anon, authenticated;
grant select on public.pronunciation_issues to authenticated;
drop policy if exists "pronunciation_issues: read own" on public.pronunciation_issues;
create policy "pronunciation_issues: read own" on public.pronunciation_issues
  for select to authenticated using (user_id = auth.uid());

-- その他の名前をそろえる (アプリの SoundTypes.NormalizeOtherName と同じ):
-- 小文字 → カッコとその中身を取る → sound / sounds を取る → 英字・数字・空白・/ - だけ → 空白 1 つ → 前後の空白 → 30 文字まで
create or replace function public._sound_label(p_name text)
returns text
language sql
immutable
as $$
  select btrim(left(btrim(regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(
                 regexp_replace(lower(coalesce(p_name, '')), '\([^)]*\)', ' ', 'g'),
                 '\msounds?\M', ' ', 'g'),
               '[\s\u00a0]', ' ', 'g'),          -- タブ・改行・幅のある空白は普通の空白 (アプリと同じ)
             '[^a-z0-9 /-]', '', 'g'),
           ' +', ' ', 'g')), 30))
$$;

drop function if exists public.save_pronunciation_issues(text, jsonb, timestamptz);
drop function if exists public.get_my_weak_sounds(integer, text);

-- p_issues: [{sound, label, weight, word, source}]、1 回 20 件まで。保存した件数を返す
create function public.save_pronunciation_issues(p_timezone text, p_issues jsonb, p_taken_at timestamptz default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_date  date;
  v_item  jsonb;
  v_sound text;
  v_label text;
  v_src   text;
  v_n     integer := 0;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if p_issues is null or jsonb_typeof(p_issues) <> 'array' then
    raise exception 'p_issues must be an array' using errcode = '22023';
  end if;
  v_date := public._practice_date(p_taken_at, coalesce(p_timezone, 'Asia/Tokyo'));

  for v_item in select value from jsonb_array_elements(p_issues) loop
    exit when v_n >= 20;
    continue when jsonb_typeof(v_item) <> 'object';
    v_sound := coalesce(v_item->>'sound', '');
    continue when v_sound not in ('th', 'r_l', 'v_b', 'f_h', 's_sh', 'vowel', 'long_short',
                                  'final_consonant', 'extra_vowel', 'stress', 'other');
    v_label := case when v_sound = 'other' then public._sound_label(v_item->>'label') else '' end;
    continue when v_sound = 'other' and v_label = '';
    v_src := coalesce(v_item->>'source', '');
    if v_src not in ('check', 'read_aloud', 'repeat', 'karaoke') then v_src := 'repeat'; end if;

    insert into public.pronunciation_issues (user_id, entry_date, sound, label, weight, word, source)
    values (v_uid, v_date, v_sound, v_label,
            case when (v_item->>'weight') = '3' then 3 else 1 end,
            left(btrim(coalesce(v_item->>'word', '')), 40),
            v_src);
    v_n := v_n + 1;
  end loop;

  -- 90 日より古いものと、1 人 500 件を超えた古いものを消す
  delete from public.pronunciation_issues
   where user_id = v_uid and entry_date < v_date - 90;
  delete from public.pronunciation_issues r
   where r.user_id = v_uid
     and r.id in (select id from public.pronunciation_issues
                   where user_id = v_uid
                   order by entry_date desc, id desc
                   offset 500);
  return v_n;
end;
$$;

-- 直近 p_days 日の苦手な発音 (sound と label の組ごと、points の多い順)。
-- previous_points はその前の同じ長さ (p_days が 45 日を超えるときは null)。words は新しい順・重なりなし・最大 5
create function public.get_my_weak_sounds(p_days integer default 30, p_timezone text default 'Asia/Tokyo')
returns table (sound text, label text, points integer, previous_points integer, words jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_today date;
  v_days  integer := least(greatest(coalesce(p_days, 30), 1), 365);
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  v_today := public.app_today(coalesce(p_timezone, 'Asia/Tokyo'));
  return query
  with cur as (
    select p.sound, p.label, sum(p.weight)::integer as points
      from public.pronunciation_issues p
     where p.user_id = v_uid and p.entry_date > v_today - v_days and p.entry_date <= v_today
     group by p.sound, p.label
  )
  select c.sound, c.label, c.points,
         case when v_days > 45 then null else
           coalesce((select sum(q.weight)::integer from public.pronunciation_issues q
                      where q.user_id = v_uid and q.sound = c.sound and q.label = c.label
                        and q.entry_date > v_today - 2 * v_days and q.entry_date <= v_today - v_days), 0)
         end,
         coalesce((select jsonb_agg(w.word order by w.last_id desc)
                     from (select x.word, max(x.id) as last_id
                             from public.pronunciation_issues x
                            where x.user_id = v_uid and x.sound = c.sound and x.label = c.label and x.word <> ''
                              and x.entry_date > v_today - v_days and x.entry_date <= v_today
                            group by x.word
                            order by max(x.id) desc
                            limit 5) w), '[]'::jsonb)
    from cur c
   order by c.points desc, c.sound, c.label;
end;
$$;

revoke all on function public._sound_label(text) from public, anon;
grant execute on function public._sound_label(text) to authenticated;
revoke all on function public.save_pronunciation_issues(text, jsonb, timestamptz) from public, anon;
revoke all on function public.get_my_weak_sounds(integer, text) from public, anon;
grant execute on function public.save_pronunciation_issues(text, jsonb, timestamptz) to authenticated;
grant execute on function public.get_my_weak_sounds(integer, text) to authenticated;
