// Claude との英語の会話で直してもらったミスを、Web (Supabase) に送る — Google Apps Script 版。
// Google のサーバーで動くので、パソコンが切れていても動く (PowerShell 版 chat-sync.ps1 と同じ働き)。
//
// 使い方 (1 回だけ):
//   1. https://script.google.com で「新しいプロジェクト」を作り、このファイルの中身を全部貼る。
//   2. 左の「プロジェクトの設定」→「スクリプト プロパティ」に 4 つ足す:
//        SUPABASE_URL       config.js の SUPABASE_URL
//        SUPABASE_ANON_KEY  config.js の SUPABASE_ANON_KEY
//        EMAIL / PASSWORD   Web にログインするメールとパスワード
//   3. 上の関数の選択で setup を選んで「実行」(初回は Google の許可を求められる)。
//      3 時間ごとに syncChatMistakes が動くようになり、すぐに 1 回送る。
// ログは左の「実行数」で見られる。止めるときは removeTriggers を実行する。
//
// Claude は Google ドライブの claude-english-mistakes フォルダに YYYY-MM-DD_chat.json を置く。
// まだ送っていない分を save_chat_day (supabase/chat.sql) で送る。送った日は連続記録にも数える。

const FOLDER_NAME = 'claude-english-mistakes';
const BATCH = 20;   // save_chat_day は 1 回に 20 件まで受け取る

function setup() {
  removeTriggers();
  ScriptApp.newTrigger('syncChatMistakes').timeBased().everyHours(3).create();
  syncChatMistakes();
}

function removeTriggers() {
  ScriptApp.getProjectTriggers()
    .filter((t) => t.getHandlerFunction() === 'syncChatMistakes')
    .forEach((t) => ScriptApp.deleteTrigger(t));
}

function syncChatMistakes() {
  const props = PropertiesService.getScriptProperties();
  const cfg = {
    url: (props.getProperty('SUPABASE_URL') || '').replace(/\/$/, ''),
    key: props.getProperty('SUPABASE_ANON_KEY'),
    email: props.getProperty('EMAIL'),
    password: props.getProperty('PASSWORD'),
  };
  if (!cfg.url || !cfg.key || !cfg.email || !cfg.password) {
    throw new Error('スクリプト プロパティに SUPABASE_URL / SUPABASE_ANON_KEY / EMAIL / PASSWORD を入れてください');
  }

  const folders = DriveApp.getFoldersByName(FOLDER_NAME);
  if (!folders.hasNext()) { console.log('フォルダがまだありません: ' + FOLDER_NAME); return; }
  const folder = folders.next();

  // 送った記録: { "2026-11-19_chat.json": 11 }  (そのファイルの先頭から何件送ったか)
  const sent = JSON.parse(props.getProperty('SENT') || '{}');

  const files = [];
  const it = folder.getFiles();
  while (it.hasNext()) {
    const f = it.next();
    if (/^\d{4}-\d{2}-\d{2}_chat\.json$/.test(f.getName())) files.push(f);
  }
  files.sort((a, b) => a.getName().localeCompare(b.getName()));

  let token = null;
  let total = 0;
  for (const f of files) {
    const name = f.getName();
    let data;
    try {
      data = JSON.parse(f.getBlob().getDataAsString('UTF-8'));
    } catch (e) {
      console.log('読めないファイルを飛ばします: ' + name + ' (' + e.message + ')');
      continue;
    }
    const date = /^\d{4}-\d{2}-\d{2}$/.test(data.date || '') ? data.date : name.slice(0, 10);
    const tz = data.timezone || 'Asia/Tokyo';
    const mistakes = Array.isArray(data.mistakes) ? data.mistakes : [];

    const done = name in sent ? sent[name] : -1;   // -1 = まだ一度も送っていない
    if (done >= 0 && done >= mistakes.length) continue;   // 新しい分が無い

    // 同じ日のファイルに後から足された分だけ送る。ミスが 0 件の日も 1 回送って連続記録に数える
    const offsets = [];
    if (mistakes.length === 0) offsets.push(0);
    else for (let i = Math.max(done, 0); i < mistakes.length; i += BATCH) offsets.push(i);

    for (const off of offsets) {
      // note (日本語の説明) は Web の表に列が無いので、type / wrong / fixed だけ送る
      const payload = mistakes.slice(off, off + BATCH).map((m) => ({
        type: String(m.type || ''), wrong: String(m.wrong || ''), fixed: String(m.fixed || ''),
      }));
      const key = name + '#' + off;
      if (!token) token = login_(cfg);

      const res = post_(cfg, '/rest/v1/rpc/save_chat_day', token,
        { p_file_key: key, p_date: date, p_mistakes: payload, p_timezone: tz });
      if (res.code >= 200 && res.code < 300) {
        const row = (res.body || [])[0] || {};
        if (row.already_sent) console.log('送信済みでした: ' + key);
        else { console.log('送りました: ' + key + '  ミス ' + row.saved + ' 件  連続記録 ' + row.streak + ' 日'); total += row.saved || 0; }
      } else if (/invalid date/.test(res.text)) {
        console.log('日付が古すぎる (90 日より前) か未来なので飛ばします: ' + key);
      } else {
        console.log('送れませんでした (次の実行でもう一度): ' + key + '  ' + res.code + ' ' + res.text);
        break;
      }
      sent[name] = Math.min(off + BATCH, mistakes.length);
      props.setProperty('SENT', JSON.stringify(sent));
    }
  }
  console.log('おわり (新しく送ったミス: ' + total + ' 件)');
}

function login_(cfg) {
  const res = post_(cfg, '/auth/v1/token?grant_type=password', null, { email: cfg.email, password: cfg.password });
  if (res.code !== 200 || !res.body || !res.body.access_token) {
    throw new Error('ログインできませんでした: ' + res.code + ' ' + res.text);
  }
  return res.body.access_token;
}

function post_(cfg, path, token, body) {
  const headers = { apikey: cfg.key };
  if (token) headers.Authorization = 'Bearer ' + token;
  const r = UrlFetchApp.fetch(cfg.url + path, {
    method: 'post', contentType: 'application/json; charset=utf-8', headers: headers,
    payload: JSON.stringify(body), muteHttpExceptions: true,
  });
  const text = r.getContentText('UTF-8');
  let parsed = null;
  try { parsed = JSON.parse(text); } catch (e) { /* 本文が JSON でないとき */ }
  return { code: r.getResponseCode(), text: text, body: parsed };
}
