# AGENTS.md — Web 版とデータベースの地図

このリポジトリは、英語の練習アプリ (Unity、隣のフォルダ `../My project`) の
**Supabase のデータベース (SQL)** と、**記録を見る Web ページ** です。
アプリ全体の説明は `../My project/AGENTS.md` を先に読んでください。
コメント・説明・コミットメッセージは**やさしい日本語**で書きます。

## 公開のしかた (大事)

- Web は Vercel で公開している。**Vercel は `main` ブランチだけを本番に出す。** ほかのブランチに push するとプレビューだけが作られる。
- ふだんの作業は `develop-words-book`。本番に出すときは `develop-words-book` を `main` に入れて push する。
- ビルドは無い。`index.html` と `src/` をそのまま配っている (`config.js` に Supabase の URL と anon キー。anon キーは公開してよい鍵)。
- **SQL を変えたら、Supabase の SQL Editor で、その .sql を流し直す。** 本番の Web を出す前に流しておく (流していないと、その欄にエラーが出る)。
- どの .sql も、何度流しても壊れないように書く (`create table if not exists`、`add column if not exists`、`drop function if exists` してから `create function`)。

## フォルダ

| 場所 | 中身 |
|---|---|
| `index.html` | 画面全部。ページは `<div class="page" data-page="...">` で、メニューの `.menu-item[data-page]` で切り替える |
| `src/main.js` | 入口 |
| `src/streak-client.js` | Supabase を呼ぶ関数 (`api.*`)。**RPC の結果を決まった項目だけ写し直しているので、SQL に列を足したらここにも足す** |
| `src/page/core.js` | 小さな部品 (`$` `el` `tr` `say` `videoLink` `adviceBlock`) と、日本語 / English の切り替え |
| `src/page/nav.js` | メニューとページの切り替え。ページを足すときは `PAGES` と `PAGES_EN` に足す (URL の `#名前` でも開ける) |
| `src/page/streak.js` | 連続記録とカレンダー。ログインしたら全部のページのデータを読む (`loadStreak`) |
| `src/page/diary.js` `summary.js` `topic.js` `repeat.js` | 日記の履歴・要約・お題・リピーティング (シャドーイングは動画のリンクとアドバイスも出す) |
| `src/page/mistakes.js` | よくあるミス (ミスの数・苦手な発音・単語の発音) |
| `src/practice-logs.js` | 単語の発音・短い答え (`#answer` のページ)・カラオケ (`#karaoke` のページ) の一覧。表を直接 `select` している |
| `src/styles.css` | 見た目 (ライト / ダーク) |
| `supabase/*.sql` | 表・関数・権限。流す順番は `README.md` を見る |
| `supabase/tests/*.sql` | SQL のテスト (psql で流す) |
| `tests/web_test.py` | Web のテスト (Playwright。Supabase をまねた偽のデータで画面を確かめる) |

## SQL の決まり

- アプリからの書き込みは **RPC (関数) だけ**。表には `select` だけを許し、RLS で自分の行だけ見えるようにする。
- 関数は `security definer` + `set search_path = public`。最初に `auth.uid()` が null なら止める。
- 引数は `p_` で始まる snake_case。新しい引数には既定値を付ける (古いアプリでも動くように)。引数を変えたら、古い形の関数を `drop function if exists` で消す。
- 「やった日」は `activity_days` の `kind` で数える (`diary` `summary` `topic` `repeat` `vocab` `answer` `karaoke` `talk` `chat`)。種類を足すときは、全部の .sql にある `activity_days_kind_check` をそろえる。
- 1 人の行数に上限がある表は、保存のときに古いものを消す。

## データの決まり

- シャドーイング (`repeat_results` の `mode = 'shadow'`) は、他人の動画の文字起こしなので、英文と言った内容を保存しない。点数・動画 (`video_id` `video_title`)・Gemini のアドバイス (`advice`) だけ。
- 画面に文字を入れるときは `textContent` を使う (`el()` はそうなっている)。`innerHTML` は使わない (テストで script の注入を確かめている)。

## テスト

- `supabase/tests/*.sql` は psql、`tests/web_test.py` は Python + Playwright。このパソコンには入っていないことがある。動かせなかったら、動かせなかったと書く。
- JavaScript は少なくとも `node --check ファイル名` で文法を確かめる。
