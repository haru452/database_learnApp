# 学習ストリーク・日記（Supabase + Web 版）

英語日記アプリ [Learningapp](https://github.com/haru452/Learningapp) で使っている、**データベース（Supabase）と Web 版**のコードです。

- メール / パスワードでのログイン
- 連続記録（ストリーク）の保存と表示
- 添削した日記の保存（直近 7 日分）と、Web での閲覧
- 要約練習（Versant 対策）の採点結果の保存と、Web での点数の推移・項目ごとの内訳（内容 50 / 構成 25 / 文法・語彙 25）のグラフ
- お題スピーキングの採点結果の保存と、Web での点数の推移・内訳（内容 40 / 構成 30 / 文法・語彙 30）
- 添削で見つかったミスの種類ごとの集計（Web の「よくあるミス」。アプリの「今日の注意」と採点の重点チェックにも使う）
- やった日カレンダー（日記 = オレンジ / 要約 = 青 / お題 = 緑 / 2種類 = 紫 / 3つ全部 = 金）

ストリークはアプリで日記を添削したときに記録され、Web 版ではアプリと同じ記録と日記の履歴を見られます。

📝 アプリ全体の解説記事（Qiita）：[Unity で「話した英語を AI が添削してくれる」英語日記アプリを作った](https://qiita.com/haru452/items/8656d7d15db5d20c7b41)

## フォルダ構成

| ファイル | 役割 |
|---|---|
| `supabase/schema.sql` | テーブル、アクセス制限（RLS）、ストリークや日記を扱う関数 |
| `supabase/summary.sql` | 要約練習の採点結果のテーブルと関数（追加分） |
| `supabase/topic.sql` | お題スピーキングの結果・よくあるミスのテーブルと関数（追加分） |
| `supabase/tests/` | SQL のテスト（手元の PostgreSQL で `psql -f topic_test.sql`） |
| `tests/web_test.py` | Web 版のテスト（Playwright。Supabase はダミーに差し替える） |
| `src/streak-client.js` | ログイン・ストリーク・日記を呼ぶモジュール（どのフレームワークでも使える） |
| `index.html` + `config.js` | Web 版の画面。そのまま Vercel に公開できる |
| `.env.example` | Vite / Next.js に組み込むときの環境変数のひな形 |

## 仕組み

ストリークや日記の読み書きは、ブラウザやアプリからテーブルを直接触るのではなく、**Supabase のデータベース側の関数（RPC）**で行います。

| 関数 | 呼ぶ場所 | 内容 |
|---|---|---|
| `complete_study` | アプリ | 今日を「書いた日」として記録する |
| `get_my_streak` | アプリ・Web | 今の連続日数・最長記録・今日書いたかを返す |
| `import_local_streak` | アプリ | ログイン前に端末で数えていた連続日数を、クラウドに引き継ぐ |
| `save_diary_entry` | アプリ | 添削した日記を保存する（直近 7 日分だけ残す） |
| `get_my_diary` | Web | 自分の日記の履歴を返す |
| `save_summary_result` | アプリ | 要約練習の採点結果（合計と項目ごとの点数）を保存する。合計が内訳と合っているかを確かめる。1人あたり新しい 20 件だけ残し、古いものは自動で消す |
| `get_my_summary_results` | Web | 自分の採点結果を新しい順に返す（点数の推移グラフ用） |

`complete_study` の判定ルールは次のとおりです。

- 最後に書いた日が **昨日** → 連続日数 +1
- 最後に書いた日が **今日** → そのまま（同じ日に何回呼んでも、加算は1回だけ）
- **2日以上空いている / 初回** → 1 にリセット

関数にした理由は2つです。端末の時計を変えても不正に伸ばせないことと、同時に呼ばれても二重に加算されないことです。「今日」は、サーバーの時刻を利用者のタイムゾーン（例：`Asia/Tokyo`）で換算して決めます。

テーブルは、ブラウザやアプリから直接書き換えられません（本人の行を **読む** ことだけ許可しています）。すべての関数は、ログインしたユーザーだけが呼べます。

---

## 1. Supabase の準備

1. [supabase.com](https://supabase.com) で **New project** を作る（Region は `Northeast Asia (Tokyo)` がおすすめ）。データベースのパスワードは控えておく。
2. 左メニューの **SQL Editor** → **New query** を開き、`supabase/schema.sql` の中身をすべて貼り付けて **Run**。`Success` と出ればよい（何度実行しても問題ない）。
   続けて、`supabase/summary.sql` → `supabase/topic.sql` の順に、同じように **Run** する（要約練習・お題スピーキングの点数と、よくあるミスを保存・表示するため）。順番を変えるとエラーになる。
3. **Authentication → Sign In / Providers → Email** が有効になっているか確認する。
   - **Confirm email**（メール確認）：本番は ON のまま。ON の場合、登録後に届く確認メールのリンクを開くまでログインできない。
   - 家族や自分だけで使う場合は、アカウントを作ったあとに **Allow new users to sign up** をオフにすると、知らない人が登録できなくなる。
4. **Project Settings → API**（または API Keys）を開き、次の2つを控える。
   - **Project URL**（`https://xxxx.supabase.co`）
   - **anon public** キー（新しい画面では **publishable key** と表示されることがある）

   `service_role` / secret キーは、**絶対にブラウザ側のコード、アプリ、Vercel の公開用の環境変数に入れない**。

## 2. Web 版を使う

`config.js` の2行を、手順 1-4 の値に書き換える。

```js
export const SUPABASE_URL = "https://xxxx.supabase.co";
export const SUPABASE_ANON_KEY = "ここに anon キー";
```

ローカルで試すには、このフォルダで次を実行して `http://localhost:3000` を開く。

```
npx serve .
```

anon キーは「公開される前提」の鍵なので、`config.js` を GitHub に上げても問題ない。データの保護は、`schema.sql` の RLS と関数の権限が担っている。

## 3. アプリ（Unity）から使う

アプリ（[Learningapp](https://github.com/haru452/Learningapp)）の `Assets/Resources/ApiSecrets.json` に、手順 1-4 の値を書く。

```json
{
  "supabaseUrl": "https://xxxx.supabase.co",
  "supabaseAnonKey": "ここに anon キー"
}
```

アプリは Supabase の REST API（`/rest/v1/rpc/関数名`）を直接呼んでいる。

## 4. 別の Web アプリに組み込む

`src/streak-client.js` をアプリにコピーし、Supabase のクライアントを渡す。

```bash
npm install @supabase/supabase-js
```

```js
import { createClient } from "@supabase/supabase-js";
import { createStreakApi, friendlyError } from "./streak-client.js";

// Vite の場合: import.meta.env.VITE_SUPABASE_URL
// Next.js の場合: process.env.NEXT_PUBLIC_SUPABASE_URL
const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
);
export const api = createStreakApi(supabase);
```

使い方（画面側）：

```js
await api.signUp(email, password);      // { needsEmailConfirmation }
await api.signIn(email, password);
await api.signOut();

const { streak, studiedToday } = await api.getStreak();   // 画面に表示する連続日数
const diary = await api.getDiary();                        // 日記の履歴（直近 7 日分）
await api.completeStudy();                                 // 今日を記録する（Web 版の画面では使っていない）

api.onAuthChange((user) => { /* user が null ならログアウト状態 */ });
friendlyError(error);                                      // エラーを日本語のメッセージにする
```

React の場合は、`useEffect` で `api.onAuthChange` を登録し、戻り値（解除用の関数）を `return` する。`index.html` の中のスクリプトが、そのまま参考になる。

`getStreak()` が返す `streak` は、**いま有効な** 連続日数。最後に書いた日が一昨日以前なら、途切れているので `0` になる（テーブルの値は、次に書くまで更新されないため、DB の値をそのまま表示しない）。

Next.js などでサーバー側の描画（SSR）も使う場合は、Supabase 公式の `@supabase/ssr` を使う構成が別途必要になる（この手順は、ブラウザだけで完結する構成）。

---

## 5. Vercel で公開する

### 5-1. GitHub に上げる

このフォルダ（または、組み込み済みのアプリ）を GitHub のリポジトリに push する。

### 5-2. Vercel にインポートする

1. [vercel.com](https://vercel.com) にログインし、**Add New → Project** で、GitHub のリポジトリを選んで **Import**。
2. **Framework Preset** を選ぶ。
   - この `index.html` のまま公開する場合：**Other**（Build Command と Output Directory は、空のままでよい）
   - Vite / Next.js などのアプリ：自動で検出される。そのまま使う。

### 5-3. 環境変数を設定する（Vite / Next.js の場合）

Import の画面の **Environment Variables**（またはあとから **Settings → Environment Variables**）に、次の2つを追加する。**Production / Preview / Development** のすべてにチェックを入れておく。

| フレームワーク | 名前 | 値 |
|---|---|---|
| Vite | `VITE_SUPABASE_URL` | Project URL |
| Vite | `VITE_SUPABASE_ANON_KEY` | anon キー |
| Next.js | `NEXT_PUBLIC_SUPABASE_URL` | Project URL |
| Next.js | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | anon キー |

- 環境変数は、**ビルド時に** コードへ埋め込まれる。値を追加・変更したあとは、**Deployments から Redeploy** しないと反映されない。
- この `index.html` のまま（ビルドなし）で公開する場合は、環境変数は使えないので、`config.js` に値を書く（手順 2）。

### 5-4. Deploy を押す

数十秒で `https://（プロジェクト名）.vercel.app` が発行される。

### 5-5. Supabase に、公開した URL を教える（必須）

**Supabase → Authentication → URL Configuration** で、次を設定する。

- **Site URL**：`https://（プロジェクト名）.vercel.app`
- **Redirect URLs** に追加：
  - `https://（プロジェクト名）.vercel.app/**`
  - `http://localhost:3000/**`（ローカルで試す場合）

ここを設定しないと、新規登録の **確認メールのリンクが、`localhost` を指したり、エラーになったりする**。

### 5-6. 公開後の確認

1. 公開 URL を開き、**アカウントを作成** する（アプリと同じアカウントでログインする）。
2. 確認メールが ON の場合は、届いたメールのリンクを開き、**ログイン** する。
3. アプリで日記を添削すると、Web 版の連続日数が増え、「日記の履歴」に添削した日記が表示される。

---

## つまずいたとき

| 症状 | 原因と対処 |
|---|---|
| 画面に「設定が必要です」と出る | `config.js` の値が、書き換わっていない |
| `Invalid API key` / 401 | anon キーが違う。Project URL と、同じプロジェクトのキーか確認する |
| `function public.xxx ... does not exist`（404） | `schema.sql` が実行されていない。SQL Editor で実行する |
| `permission denied for function` | 未ログインのまま呼んでいる。ログインしているか確認する |
| 確認メールが届かない | 迷惑メールを確認する。Supabase 標準のメール送信は、回数の制限が厳しい。本番は、自前の SMTP の設定を推奨 |
| 確認メールのリンクが、`localhost` を指す | 手順 5-5 の Site URL を設定する |
| Vercel で環境変数が `undefined` | 名前の接頭辞（`VITE_` / `NEXT_PUBLIC_`）を確認し、設定後に Redeploy する |
| ストリークが、日付の変わり目でずれる | 「今日」は、端末のタイムゾーンで決まる。端末のタイムゾーンの設定を確認する |

## セキュリティのメモ

- ブラウザやアプリに置いてよいのは **Project URL と anon キーだけ**。`service_role` キーは、このアプリには不要。
- データへのアクセス制限は RLS と関数の権限が担っている。テーブルは、ブラウザやアプリから直接書き込めない。
- ストリークや日記の読み書きは、ログイン済みのユーザーが、自分のデータに対してだけ行える。
- Supabase のダッシュボードの **Advisors → Security Advisor** で、RLS の付け忘れなどを確認できる。

## 関連リポジトリ

| リポジトリ | 内容 |
|---|---|
| [Learningapp](https://github.com/haru452/Learningapp) | アプリ本体（Unity） |
| [my-project-connected-to-discord](https://github.com/haru452/my-project-connected-to-discord) | 日記のリマインダー（Cloudflare Workers） |
