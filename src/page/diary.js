import { $, el, fe, locale, say, tr } from "./core.js";
import { api } from "./supabase.js";
import { isoDate, renderStreak } from "./streak.js";

// ---------- 日記の履歴 (文章は textContent で入れる。HTML として解釈させない) ----------

export function formatDay(isoDate) {
  const d = new Date(isoDate + "T00:00:00");
  return isNaN(d) ? isoDate : d.toLocaleDateString(locale(), { month: "long", day: "numeric", weekday: "short" });
}

export function formatTime(iso) {
  const d = new Date(iso);
  return isNaN(d) ? "" : d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
}

export function renderDiary(entries) {
  const list = $("diary-list");
  list.replaceChildren();
  if (entries.length === 0) {
    list.append(el("p", "empty", tr("まだ日記がありません。アプリで日記を添削すると、ここに表示されます。",
      "No diary entries yet. They appear here once you correct a diary entry in the app.")));
    return;
  }
  let lastDate = null;
  for (const e of entries) {
    if (e.date !== lastDate) {
      list.append(el("div", "day", formatDay(e.date)));
      lastDate = e.date;
    }
    const card = el("div", "entry");
    card.append(el("div", "meta", [formatTime(e.createdAt), e.engine].filter(Boolean).join("  ·  ")));
    card.append(el("div", "lbl", tr("あなたの文章", "What you wrote")));
    card.append(el("p", "", e.original));
    card.append(el("div", "lbl fix", tr("添削後", "Corrected")));
    card.append(el("p", "", e.corrected));
    if (e.explanation) card.append(el("p", "exp", e.explanation));
    list.append(card);
  }
}

export async function loadDiary() {
  say($("diary-msg"), "");
  try {
    renderDiary(await api.getDiary());
  } catch (err) {
    say($("diary-msg"), fe(err), "error");
  }
}

$("complete").addEventListener("click", async () => {
  $("complete").disabled = true;   // 連打を防ぐ
  say($("app-msg"), "");
  try {
    const r = await api.completeStudy();
    renderStreak({ streak: r.streak, studiedToday: true, best: r.best });
    say($("app-msg"),
      r.alreadyDone ? tr("今日はすでに完了しています。", "Already done for today.")
        : tr(`${r.streak}日連続になりました。`, `${r.streak}-day streak!`),
      "ok");
  } catch (err) {
    say($("app-msg"), fe(err), "error");
    $("complete").disabled = false;
  }
});
