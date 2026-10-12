# 学習ストリーク（Supabase + Vercel）

メール/パスワードのログインと、連続学習記録（ストリーク）の保存・表示。

## フォルダ構成

| ファイル | 役割 |
|---|---|
| `supabase/schema.sql` | テーブル、アクセス制限（RLS）、「学習完了」の判定を行う関数 |
| `src/streak-client.js` | ログイン・ストリークを呼ぶモジュール（どのフレームワークでも使える） |
| `index.html` + `config.js` | 動作確認用の画面。そのまま Vercel に公開もできる |
| `.env.example` | Vite / Next.js に組み込むときの環境変数のひな形 |

## 仕組み

「学習完了」の判定は、ブラウザではなく **Supabase のデータベース側の関数**（`complete_study`）で行う。

- 最後の学習日が **昨日** → 連続日数 +1
- 最後の学習日が **今日** → そのまま
- **2日以上空いている / 初回** → 1 にリセット
- 同時に `last_study_date` を今日に更新

理由は2つ。端末の時計を変えても不正に伸ばせないことと、ボタンを連打・同時に押しても二重に加算されないこと。「今日」は、サーバーの時刻を、利用者の端末のタイムゾーン（例: `Asia/Tokyo`）で換算して決める。

テーブルはブラウザから直接書き換えられない（本人の行を **読む** ことだけ許可している）。

---

## 1. あなたが準備すること（Supabase）

1. [supabase.com](https://supabase.com) で **New project** を作る（Region は `Northeast Asia (Tokyo)` がおすすめ）。データベースのパスワードは、控えておく。
2. 左メニューの **SQL Editor** → **New query** を開き、`supabase/schema.sql` の中身をすべて貼り付けて **Run**。`Success` と出ればよい（何度実行しても問題ない）。
3. **Authentication → Providers → Email** が有効になっているか確認する。
   - **Confirm email**（メール確認）: 本番は ON のまま。開発中に手軽に試したいときだけ OFF にする。ON の場合、登録後に届く確認メールのリンクを開くまでログインできない。
4. **Project Settings → API**（または API Keys）を開き、次の2つを控える。
   - **Project URL**（`https://xxxx.supabase.co`）
   - **anon public** キー（新しい画面では **publishable key** と表示されることがある）

   `service_role` / secret キーは、**絶対にブラウザ側のコードや Vercel の公開用の環境変数に入れない**。

## 2. 動作確認用の画面を使う場合

`config.js` の2行を、手順 1-4 の値に書き換える。

```js
export const SUPABASE_URL = "https://xxxx.supabase.co";
export const SUPABASE_ANON_KEY = "ここに anon キー";
```

ローカルで試すには、このフォルダで次を実行して `http://localhost:3000` を開く。

```
npx serve .
```

anon キーは「公開される前提」の鍵なので、`config.js` を GitHub に上げても問題ない。データの保護は、`schema.sql` の RLS が担っている。

## 3. 既存のアプリに組み込む

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

使い方（画面側）:

```js
await api.signUp(email, password);      // { needsEmailConfirmation }
await api.signIn(email, password);
await api.signOut();

const { streak, studiedToday } = await api.getStreak();   // 画面に表示する連続日数
const result = await api.completeStudy();                  // 「学習完了」ボタン → { streak, alreadyDone }

api.onAuthChange((user) => { /* user が null ならログアウト状態 */ });
friendlyError(error);                                      // エラーを日本語のメッセージにする
```

React の場合は、`useEffect` で `api.onAuthChange` を登録し、戻り値（解除用の関数）を `return` する。`index.html` の中のスクリプトが、そのまま参考になる。

`getStreak()` が返す `streak` は、**いま有効な** 連続日数。最後の学習が一昨日以前なら、途切れているので `0` になる（テーブルの値は、次に学習するまで更新されないため、DB の値をそのまま表示しない）。

Next.js などでサーバー側の描画（SSR）も使う場合は、Supabase 公式の `@supabase/ssr` を使う構成が別途必要になる（この手順は、ブラウザだけで完結する構成）。

---

## 4. Vercel で公開する

### 4-1. GitHub に上げる

このフォルダ（または、組み込み済みの既存アプリ）を GitHub のリポジトリに push する。

### 4-2. Vercel にインポートする

1. [vercel.com](https://vercel.com) にログインし、**Add New → Project** で、GitHub のリポジトリを選んで **Import**。
2. **Framework Preset** を選ぶ。
   - この `index.html` のまま公開する場合: **Other**（Build Command と Output Directory は、空のままでよい）
   - Vite / Next.js などの既存アプリ: 自動で検出される。そのまま使う。

### 4-3. 環境変数を設定する（Vite / Next.js の場合）

Import の画面の **Environment Variables**（またはあとから **Settings → Environment Variables**）に、次の2つを追加する。**Production / Preview / Development** のすべてにチェックを入れておく。

| フレームワーク | 名前 | 値 |
|---|---|---|
| Vite | `VITE_SUPABASE_URL` | Project URL |
| Vite | `VITE_SUPABASE_ANON_KEY` | anon キー |
| Next.js | `NEXT_PUBLIC_SUPABASE_URL` | Project URL |
| Next.js | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | anon キー |

- 環境変数は、**ビルド時に** コードへ埋め込まれる。値を追加・変更したあとは、**Deployments から Redeploy** しないと反映されない。
- この `index.html` のまま（ビルドなし）で公開する場合は、環境変数は使えないので、`config.js` に値を書く（手順 2）。

### 4-4. Deploy を押す

数十秒で `https://（プロジェクト名）.vercel.app` が発行される。

### 4-5. Supabase に、公開したURLを教える（必須）

**Supabase → Authentication → URL Configuration** で、次を設定する。

- **Site URL**: `https://（プロジェクト名）.vercel.app`
- **Redirect URLs** に追加:
  - `https://（プロジェクト名）.vercel.app/**`
  - `http://localhost:3000/**`（ローカルで試す場合）

ここを設定しないと、新規登録の **確認メールのリンクが、`localhost` を指したり、エラーになったりする**。

### 4-6. 公開後の確認

1. 公開URLを開き、**アカウントを作成** する。
2. 確認メールが ON の場合は、届いたメールのリンクを開き、**ログイン** する。
3. 画面に `0 日連続` が表示される。
4. **今日の学習を完了する** を押すと `1 日連続` になり、ボタンが「今日は完了済みです」に変わる。
5. もう一度押そうとしても、増えない（ボタンが押せない）。

翌日に同じ操作をすると `2 日連続`、1日休んで翌々日に押すと `1 日連続` に戻る。

---

## つまずいたとき

| 症状 | 原因と対処 |
|---|---|
| 画面に「設定が必要です」と出る | `config.js` の値が、書き換わっていない |
| `Invalid API key` / 401 | anon キーが違う。Project URL と、同じプロジェクトのキーか確認する |
| `function public.complete_study ... does not exist`（404） | `schema.sql` が実行されていない。SQL Editor で実行する |
| `permission denied for function` | 未ログインのまま呼んでいる。ログインしているか確認する |
| 確認メールが届かない | 迷惑メールを確認する。Supabase 標準のメール送信は、回数の制限が厳しい。本番は、自前の SMTP の設定を推奨 |
| 確認メールのリンクが、`localhost` を指す | 手順 4-5 の Site URL を設定する |
| Vercel で環境変数が `undefined` | 名前の接頭辞（`VITE_` / `NEXT_PUBLIC_`）を確認し、設定後に Redeploy する |
| ストリークが、日付の変わり目でずれる | `complete_study` は、端末のタイムゾーンで「今日」を決める。端末のタイムゾーンの設定を確認する |

## セキュリティのメモ

- ブラウザに置いてよいのは **Project URL と anon キーだけ**。`service_role` キーは、サーバー側でも、このアプリには不要。
- データへのアクセス制限は RLS が担っている。`streaks` テーブルは、ブラウザから直接書き込めない。
- ストリークの更新は、ログイン済みのユーザーが、自分の行に対してだけ行える。
