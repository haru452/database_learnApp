// Diary reminder Worker
//
//  POST /ping  : アプリが「今日の日記を書いた」と連絡する  { "date": "2026-10-10", "streak": 7 }
//  POST /test  : 状態に関係なく、リマインドをすぐ Discord に送る (動作確認用)
//  POST /status: 記録の状態を JSON で返す (アプリからの連絡が届いているかの確認用)
//  POST /check : 定期実行と同じ判断を今すぐ行う。/check?dry=1 なら送信せず、判断の結果だけ返す
//  cron        : 毎日決まった時刻に、今日の日記が書かれていなければ Discord に通知する
//
// どちらの POST も  Authorization: Bearer <APP_SECRET>  が必要。

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Not found", { status: 404 });
    }
    if (!(await isAuthorized(request, env))) {
      return new Response("Unauthorized", { status: 401 });
    }

    if (url.pathname === "/ping") {
      let body;
      try {
        body = await request.json();
      } catch {
        return new Response("Bad JSON", { status: 400 });
      }

      const date = String(body.date ?? "");
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
        return new Response("Bad date", { status: 400 });
      }
      const streak = Number.isInteger(body.streak) && body.streak >= 0 ? body.streak : 0;

      // 日付が古い連絡(遅れて届いたもの)で、新しい記録を上書きしない
      const state = await readState(env);
      if (!state.lastDate || date >= state.lastDate) {
        await env.DIARY_KV.put("state", JSON.stringify({ lastDate: date, streak }));
      }
      return new Response("ok");
    }

    if (url.pathname === "/check") {
      // 定期実行と同じ処理。dry=1 のときは、Discord に送らず、判断の結果だけ返す
      try {
        const dryRun = url.searchParams.get("dry") === "1";
        return new Response(await checkAndRemind(env, { dryRun }));
      } catch (e) {
        return new Response("Failed: " + (e && e.message ? e.message : String(e)), { status: 500 });
      }
    }

    if (url.pathname === "/status") {
      // 現在の記録を確認する (アプリからの連絡が届いているかの確認用)
      const today = todayInTimezone(env);
      const state = await readState(env);
      const status = {
        today,                                   // Worker が考えている「今日」(TIMEZONE 基準)
        lastDate: state.lastDate,                // アプリから最後に連絡があった「日記を書いた日」
        streak: state.streak,
        doneToday: state.lastDate === today,     // true なら、今日はリマインドが送られない
        remindedDate: await env.DIARY_KV.get("reminded"),   // 最後にリマインドを送った日
      };
      return new Response(JSON.stringify(status, null, 2), {
        headers: { "Content-Type": "application/json" },
      });
    }

    if (url.pathname === "/test") {
      try {
        const today = todayInTimezone(env);
        await sendReminder(env, await readState(env), today);
        return new Response("sent");
      } catch (e) {
        // 原因が分かるメッセージを返す (動作確認用)
        return new Response("Failed: " + (e && e.message ? e.message : String(e)), { status: 500 });
      }
    }

    return new Response("Not found", { status: 404 });
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(
      checkAndRemind(env).then((result) => {
        console.log("[cron] " + result);   // Observability のログで、定期実行の結果を確認できる
      })
    );
  },
};

// ------------------------------------------------------------
// Reminder
// ------------------------------------------------------------
// 戻り値: 何をしたか (または、なぜ送らなかったか) の説明
async function checkAndRemind(env, { dryRun = false } = {}) {
  const today = todayInTimezone(env);
  const state = await readState(env);

  // 今日はもう書いている
  if (state.lastDate === today) {
    return `skipped: today's diary is already recorded (today=${today}, lastDate=${state.lastDate})`;
  }

  // 同じ日に二重送信しない (cron の再実行対策)
  if ((await env.DIARY_KV.get("reminded")) === today) {
    return `skipped: a reminder was already sent today (today=${today})`;
  }

  if (dryRun) {
    return `would send a reminder now (today=${today}, lastDate=${state.lastDate})`;
  }

  await sendReminder(env, state, today);
  await env.DIARY_KV.put("reminded", today);
  return `sent a reminder (today=${today}, lastDate=${state.lastDate})`;
}

async function sendReminder(env, state, today) {
  const yesterday = addDays(today, -1);

  let text;
  if (state.lastDate === yesterday && state.streak > 0) {
    // 昨日まで続いている → 今日書かないと途切れる
    text =
      "\u{1F4D3} Reminder: you haven't written today's diary yet.\n" +
      `Your **${state.streak}-day streak** ends tonight if you skip. Take a minute to speak your diary!`;
  } else {
    text = "\u{1F4D3} Reminder: you haven't written today's diary yet. Take a minute to speak your diary!";
  }

  // DISCORD_USER_ID があれば、その人にだけメンションして通知が鳴るようにする
  const userId = env.DISCORD_USER_ID;
  const payload = userId
    ? { content: `<@${userId}> ${text}`, allowed_mentions: { users: [String(userId)] } }
    : { content: text, allowed_mentions: { parse: [] } };

  const response = await fetch(getWebhookUrl(env), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    throw new Error(`Discord webhook failed: ${response.status} ${await response.text()}`);
  }
}

// ------------------------------------------------------------
// Helpers
// ------------------------------------------------------------
const DISCORD_HOSTS = ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"];

// Webhook URL が Discord のものか確認してから使う。
// (workers.dev など別の URL を登録してしまうと、Cloudflare のエラー 1042 になるため)
function getWebhookUrl(env) {
  const raw = String(env.DISCORD_WEBHOOK_URL || "").trim();
  if (!raw) {
    throw new Error("DISCORD_WEBHOOK_URL is not set. Add it as a Secret in the Worker settings.");
  }

  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error("DISCORD_WEBHOOK_URL is not a valid URL.");
  }

  if (u.protocol !== "https:" || !DISCORD_HOSTS.includes(u.hostname) || !u.pathname.startsWith("/api/webhooks/")) {
    throw new Error(
      "DISCORD_WEBHOOK_URL must look like https://discord.com/api/webhooks/<id>/<token> " +
        `(the registered URL points to host: ${u.hostname}).`
    );
  }
  return u.toString();
}

async function readState(env) {
  const raw = await env.DIARY_KV.get("state");
  if (!raw) return { lastDate: null, streak: 0 };
  try {
    const s = JSON.parse(raw);
    return { lastDate: s.lastDate ?? null, streak: s.streak ?? 0 };
  } catch {
    return { lastDate: null, streak: 0 };
  }
}

// 指定タイムゾーン (既定: Asia/Tokyo) での今日の日付 "YYYY-MM-DD"
function todayInTimezone(env) {
  const timeZone = env.TIMEZONE || "Asia/Tokyo";
  // 1日の切り替わり時刻 (例: 3 → 夜中の 3:00 までは前の日として扱う)。アプリ・Supabase と同じ値にする
  const startHour = Number(env.DAY_START_HOUR ?? 3);
  const shifted = new Date(Date.now() - startHour * 3600 * 1000);
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(shifted);
}

function addDays(dateString, delta) {
  const d = new Date(`${dateString}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + delta);
  return d.toISOString().slice(0, 10);
}

async function isAuthorized(request, env) {
  const expected = env.APP_SECRET;
  if (!expected) return false;

  const header = request.headers.get("Authorization") || "";
  const given = header.startsWith("Bearer ") ? header.slice(7) : "";
  return timingSafeEqual(given, expected);
}

// 文字列の比較にかかる時間から秘密を推測されないよう、長さが違っても同じ処理を通す
async function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const va = new Uint8Array(ha);
  const vb = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
  return diff === 0;
}
