-- 単語帳: 発音で苦手な音 (th・R と L など) があった単語を、1 回ずつそのまま残す (音ごとに合計しない)。
-- アプリはまとめの採点のあとに save_vocab_pron_logs を呼ぶ。Web の「単語の発音」で見る。
-- 何度流しても同じ状態になる。

create table if not exists public.vocab_pron_logs (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references auth.users (id) on delete cascade,
  taken_at  timestamptz not null default now(),
  word      text not null check (char_length(word) between 1 and 64),
  rating    text not null check (rating in ('good', 'close', 'practice')),
  sounds    text[] not null check (cardinality(sounds) between 1 and 2),
  advice    text not null default '' check (char_length(advice) <= 400),
  heard     text not null default '' check (char_length(heard) <= 200)
);
create index if not exists vocab_pron_logs_user_time on public.vocab_pron_logs (user_id, taken_at desc, id desc);

alter table public.vocab_pron_logs enable row level security;
revoke all on public.vocab_pron_logs from anon, authenticated;
grant select on public.vocab_pron_logs to authenticated;
drop policy if exists "vocab_pron_logs_select_own" on public.vocab_pron_logs;
create policy "vocab_pron_logs_select_own"
  on public.vocab_pron_logs for select
  to authenticated
  using (user_id = auth.uid());

-- 1 回分 (最大 20 語) を残す。苦手な音が 1 つも無い語・知らない判定の語は捨てる。知らない音のコードも捨てる。
-- p_items: [{"word":"think","rating":"close","sounds":["th"],"advice":"...","heard":"sink"}, ...]
-- 返す値: 残した数
drop function if exists public.save_vocab_pron_logs(jsonb, timestamptz);
create function public.save_vocab_pron_logs(p_items jsonb, p_taken_at timestamptz default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_n   integer;
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

  insert into public.vocab_pron_logs (user_id, taken_at, word, rating, sounds, advice, heard)
  select v_uid,
         least(coalesce(p_taken_at, now()), now()),
         lower(btrim(e.item ->> 'word')),
         e.item ->> 'rating',
         s.codes,
         left(coalesce(e.item ->> 'advice', ''), 400),
         left(coalesce(e.item ->> 'heard', ''), 200)
  from jsonb_array_elements(p_items) as e(item)
  cross join lateral (
    select array(
      select distinct c
      from jsonb_array_elements_text(
             case when jsonb_typeof(e.item -> 'sounds') = 'array' then e.item -> 'sounds' else '[]'::jsonb end) as c
      where c in ('th', 'r_l', 'v_b', 'f_h', 's_sh', 'vowel', 'long_short',
                  'final_consonant', 'extra_vowel', 'stress', 'other')
      limit 2) as codes
  ) as s
  where jsonb_typeof(e.item) = 'object'
    and char_length(btrim(coalesce(e.item ->> 'word', ''))) between 1 and 64
    and e.item ->> 'rating' in ('good', 'close', 'practice')
    and cardinality(s.codes) > 0;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.save_vocab_pron_logs(jsonb, timestamptz) from public, anon;
grant execute on function public.save_vocab_pron_logs(jsonb, timestamptz) to authenticated;
