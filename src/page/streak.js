import { $, el, fe, lang, locale, say, tr } from "./core.js";
import { api } from "./supabase.js";
import { loadDiary } from "./diary.js";
import { loadSummary } from "./summary.js";
import { loadTopic } from "./topic.js";
import { loadRepeat } from "./repeat.js";
import { loadMistakes } from "./mistakes.js";

// ---------- ストリーク ----------
export function renderStreak({ streak, studiedToday, best }) {
  $("streak-num").textContent = String(streak);
  const bestDays = Math.max(best || 0, streak);
  $("streak-best").textContent = tr(`最長記録: ${bestDays}日`, `Best: ${bestDays} ${bestDays === 1 ? "day" : "days"}`);
  $("streak-sub").textContent = studiedToday
    ? tr("今日の学習は完了しています", "You've studied today")
    : streak > 0
      ? tr("今日学習すると、連続記録が続きます", "Study today to keep your streak going")
      : tr("今日から始めましょう", "Start today");
  $("complete").disabled = studiedToday;
  $("complete").textContent = studiedToday ? tr("今日は完了済みです", "Done for today") : tr("今日の学習を完了する", "Mark today as done");
}

// 週の連続 (いつも出す)。weeks.sql を実行していないなどで読めなければ出さない
export async function loadWeekStreak() {
  const box = $("streak-weeks");
  try {
    const { weeks, thisWeekDone } = await api.getWeekStreak();
    const pending = weeks > 0 && !thisWeekDone;
    box.textContent = tr(`${weeks}週連続` + (pending ? "（今週はまだ）" : ""),
                         `${weeks}-week streak` + (pending ? " (not this week yet)" : ""));
    box.hidden = false;
  } catch (err) {
    box.hidden = true;
  }
}

export async function loadStreak() {
  say($("app-msg"), "");
  try {
    renderStreak(await api.getStreak());
  } catch (err) {
    say($("app-msg"), fe(err), "error");
  }
  loadWeekStreak();
  loadCalendar();
  loadDiary();
  loadSummary();
  loadTopic();
  loadRepeat();
  loadMistakes();
}

// ---------- やった日カレンダー (日記 = 赤 / 要約 = 青 / お題 = 緑 / リピーティング = ピンク / 単語帳 = 紫 / 2種類 = 銅 / 3〜4種類 = 銀 / 5つ全部 = 金) ----------
export const FLAME_SVG =
  '<svg class="flame" viewBox="0 0 40 46" aria-hidden="true"><path d="M20 0c1.2 3.6 3 6 4.6 8.4C25.8 6.6 27.6 5 29.2 4c4.6 5.6 7.8 12.6 7.8 21.5C37 36.6 29.4 45 20 45S3 36.6 3 25.5C3 16.6 6.2 9.6 10.8 4c1.6 1 3.4 2.6 4.6 4.4C17 6 18.8 3.6 20 0z"/></svg>';
export let calMonth = null;   // 表示中の月の1日

// 「今日」は、夜中の 3:00 までは前の日として数える (アプリ・サーバーと同じ区切り)
export function studyToday() {
  const d = new Date(Date.now() - 3 * 60 * 60 * 1000);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}
export function isoDate(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
export function addDays(d, n) { return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n); }

export async function loadCalendar(month) {
  const today = studyToday();
  const thisMonth = new Date(today.getFullYear(), today.getMonth(), 1);
  calMonth = month || calMonth || thisMonth;
  if (calMonth > thisMonth) calMonth = thisMonth;

  // 表示する6週間分 (前後の月の日も含む。日曜はじまり)
  const start = addDays(calMonth, -calMonth.getDay());
  const end = addDays(start, 41);
  $("cal-title").textContent = lang === "en"
    ? calMonth.toLocaleDateString("en-US", { year: "numeric", month: "long" })
    : `${calMonth.getFullYear()}年${calMonth.getMonth() + 1}月`;
  $("cal-next").disabled = calMonth >= thisMonth;
  say($("cal-msg"), "");

  let days = [];
  try {
    days = await api.getActivityDays(isoDate(start), isoDate(end));
  } catch (err) {
    say($("cal-msg"), fe(err), "error");
  }
  const byDate = new Map(days.map((d) => [d.date, d]));
  renderCalendar(start, today, byDate);
}

export function renderCalendar(start, today, byDate) {
  const grid = $("cal-grid");
  grid.replaceChildren();
  const todayIso = isoDate(today);
  // 最後の週が全部次の月なら、表示しない
  const weeks = addDays(start, 35).getMonth() !== calMonth.getMonth() ? 5 : 6;

  for (let i = 0; i < weeks * 7; i++) {
    const d = addDays(start, i);
    const iso = isoDate(d);
    const a = byDate.get(iso);
    const cell = el("div", "cal-day");
    cell.setAttribute("role", "gridcell");
    if (d.getMonth() !== calMonth.getMonth()) cell.classList.add("out");
    if (iso === todayIso) cell.classList.add("today");

    let label = lang === "en" ? d.toLocaleDateString("en-US", { month: "long", day: "numeric" }) : `${d.getMonth() + 1}月${d.getDate()}日`;
    const kinds = a ? [a.diary && tr("日記", "diary"), a.summary && tr("要約練習", "summary"), a.topic && tr("お題", "topic"),
                       a.repeat && tr("リピーティング", "repeating"), a.vocab && tr("単語帳", "vocabulary")]
      .filter(Boolean) : [];
    if (kinds.length > 0) {
      // 1種類 = その色 / 2種類 = 銅 / 3〜4種類 = 銀 / 5つ全部 = 金
      const kind = kinds.length >= 5 ? "gold" : kinds.length >= 3 ? "silver" : kinds.length === 2 ? "bronze"
        : a.diary ? "diary" : a.summary ? "summary" : a.topic ? "topic" : a.repeat ? "repeat" : "vocab";
      cell.classList.add("on", kind);
      // 同じ週の中で、前後の日もやっていれば帯でつなぐ
      const prev = byDate.get(isoDate(addDays(d, -1)));
      const next = byDate.get(isoDate(addDays(d, 1)));
      if (d.getDay() === 0 || !prev) cell.classList.add("first");
      if (d.getDay() === 6 || !next) cell.classList.add("last");
      cell.insertAdjacentHTML("beforeend", FLAME_SVG);
      label += (lang === "en" ? ": " + kinds.join(", ") : " " + kinds.join("・"));
    }
    cell.setAttribute("aria-label", label);
    cell.append(el("span", "n", String(d.getDate())));
    grid.append(cell);
  }
  renderMonthDays(byDate);
}

// カレンダーの下に、表示中の月にやったことを日付ごとに書く (新しい日が上。読み込み済みのデータを使うだけ)
export const KIND_INFO = [
  ["diary", "#e03131", "日記", "Diary"], ["summary", "#4dabf7", "要約練習", "Summary"],
  ["topic", "#40c057", "お題", "Topic"], ["repeat", "#f06595", "リピーティング", "Repeating"],
  ["vocab", "#845ef7", "単語帳", "Vocabulary"],
];
export const FLAME_COLORS = { 5: "#fcc419", 4: "#a3acb9", 3: "#a3acb9", 2: "#c27c3e" };
export function renderMonthDays(byDate) {
  const box = $("cal-days");
  box.replaceChildren();
  const days = [...byDate.values()]
    .filter((a) => {
      const d = new Date(a.date + "T00:00:00");
      return d.getFullYear() === calMonth.getFullYear() && d.getMonth() === calMonth.getMonth()
        && KIND_INFO.some(([k]) => a[k]);
    })
    .sort((x, y) => (x.date < y.date ? 1 : -1));
  if (days.length === 0) return;
  box.append(el("h3", "", tr("この月にやったこと", "What you did this month")));
  const ul = el("ul");
  for (const a of days) {
    const done = KIND_INFO.filter(([k]) => a[k]);
    const li = el("li");
    const date = el("span", "date", new Date(a.date + "T00:00:00")
      .toLocaleDateString(locale(), { month: "numeric", day: "numeric", weekday: "short" }));
    date.style.setProperty("--flame", FLAME_COLORS[done.length] || done[0][1]);
    const what = el("span", "what");
    for (const [, color, ja, en] of done) {
      const item = el("span", "", tr(ja, en));
      item.style.setProperty("--c", color);
      what.append(item);
    }
    li.append(date, what);
    ul.append(li);
  }
  box.append(ul);
}

$("cal-prev").addEventListener("click", () => {
  loadCalendar(new Date(calMonth.getFullYear(), calMonth.getMonth() - 1, 1));
});
$("cal-next").addEventListener("click", () => {
  loadCalendar(new Date(calMonth.getFullYear(), calMonth.getMonth() + 1, 1));
});
