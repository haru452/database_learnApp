-- ============================================================
-- 単語帳の「動画の場面」(単語が出てくる YouTube の字幕の場面)
--   他の .sql とは独立 (auth.uid() だけ使う)。何度実行しても壊れない。
--   表 vocab_clips: 直接の select/insert/update/delete は誰にも許さない (RLS 有効・方針なし)。
--     読む・足すは RPC (get_vocab_clips / add_vocab_clips) だけ。service role キーは RLS を通り越して書ける。
--   字幕の文は動画の作者の著作物なので git には入れず、Supabase にだけ置く。
-- ============================================================

create table if not exists public.vocab_clips (
  id         bigint generated always as identity primary key,
  word       text        not null check (word = lower(word)),
  video_id   text        not null,
  start_ms   integer     not null,
  end_ms     integer     not null check (end_ms > start_ms),
  sentence   text        not null default '',
  channel    text        not null default '',
  source     text        not null default 'search' check (source in ('channel', 'search')),
  created_at timestamptz not null default now(),
  unique (word, video_id, start_ms)
);

alter table public.vocab_clips enable row level security;
-- 方針は作らない。念のため API 用の役割からも権限を外す (Supabase は新しい表に全権限を付けるため)
revoke all on table public.vocab_clips from public, anon, authenticated;

-- 単語ごとに id 順で最大 10 場面を返す (単語は小文字で比べる)
drop function if exists public.get_vocab_clips(text, text[]);
create function public.get_vocab_clips(p_timezone text default null, p_words text[] default '{}')
returns setof public.vocab_clips
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  return query
    select r.id, r.word, r.video_id, r.start_ms, r.end_ms, r.sentence, r.channel, r.source, r.created_at
    from (
      select c.*, row_number() over (partition by c.word order by c.id) as rn
      from public.vocab_clips c
      where c.word = any (select lower(w) from unnest(coalesce(p_words, '{}')) as w)
    ) r
    where r.rn <= 10
    order by r.word, r.id;
end $$;
revoke all on function public.get_vocab_clips(text, text[]) from public, anon;
grant execute on function public.get_vocab_clips(text, text[]) to authenticated;

-- アプリが探して見つけた場面を足す。入れた行数を返す。
--   source は必ず 'search'。最初の 30 要素だけ見る。1 語は合計 10 場面まで。重なりは入れない。
drop function if exists public.add_vocab_clips(text, jsonb);
create function public.add_vocab_clips(p_timezone text default null, p_clips jsonb default '[]')
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_el    jsonb;
  v_word  text;
  v_vid   text;
  v_start integer;
  v_end   integer;
  v_n     integer := 0;
  v_rows  integer;
  v_seen  integer := 0;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;
  if p_clips is null or jsonb_typeof(p_clips) <> 'array' then
    return 0;
  end if;

  for v_el in select e from jsonb_array_elements(p_clips) as e loop
    v_seen := v_seen + 1;
    exit when v_seen > 30;
    if jsonb_typeof(v_el) <> 'object' then continue; end if;
    v_word := lower(btrim(coalesce(v_el->>'word', '')));
    v_vid  := btrim(coalesce(v_el->>'video_id', ''));
    if v_word = '' or v_vid = '' then continue; end if;
    begin
      v_start := (v_el->>'start_ms')::integer;
      v_end   := (v_el->>'end_ms')::integer;
    exception when others then
      continue;
    end;
    if v_start is null or v_end is null or v_end <= v_start then continue; end if;
    if (select count(*) from public.vocab_clips c where c.word = v_word) >= 10 then continue; end if;

    insert into public.vocab_clips (word, video_id, start_ms, end_ms, sentence, channel, source)
    values (v_word, v_vid, v_start, v_end,
            coalesce(v_el->>'sentence', ''), coalesce(v_el->>'channel', ''), 'search')
    on conflict (word, video_id, start_ms) do nothing;
    get diagnostics v_rows = row_count;
    v_n := v_n + v_rows;
  end loop;
  return v_n;
end $$;
revoke all on function public.add_vocab_clips(text, jsonb) from public, anon;
grant execute on function public.add_vocab_clips(text, jsonb) to authenticated;
