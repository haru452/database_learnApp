import { $, fe, onLangChange, say, show, tr } from "./core.js";
import { api } from "./supabase.js";
import { recovering, setModeLabels } from "./auth.js";
import { loadStreak } from "./streak.js";
import { TOPIC_PARTS, renderSummaryChart, renderSummaryParts, sumResults } from "./summary.js";
import { topResults } from "./topic.js";
import { REPEAT_UNIT, repDays } from "./repeat.js";

// ---------- ハンバーガーメニューとページの切り替え (URL の #diary / #summary / #topic / #repeat / #answer / #karaoke / #mistakes で直接開ける) ----------
export const PAGES = {
  home: "学習ストリーク", diary: "日記の履歴", summary: "要約練習のスコア",
  topic: "お題スピーキング", repeat: "リピーティング", answer: "短い答え", karaoke: "カラオケ", mistakes: "よくあるミス",
};
export const PAGES_EN = {
  home: "Study Streak", diary: "Diary history", summary: "Summary scores",
  topic: "Topic speaking", repeat: "Repeating", answer: "Short answers", karaoke: "Karaoke", mistakes: "Common mistakes",
};
export let currentPage = "home";

export function setMenu(open) {
  document.body.classList.toggle("menu-open", open);
  $("menu-btn").setAttribute("aria-expanded", String(open));
  if (open) $("menu-close").focus();
}
$("menu-btn").addEventListener("click", () => setMenu(true));
$("menu-close").addEventListener("click", () => { setMenu(false); $("menu-btn").focus(); });
$("menu-backdrop").addEventListener("click", () => setMenu(false));
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && document.body.classList.contains("menu-open")) { setMenu(false); $("menu-btn").focus(); }
});

export function showPage(name) {
  if (!PAGES[name]) name = "home";
  currentPage = name;
  for (const page of document.querySelectorAll(".page")) page.hidden = page.dataset.page !== name;
  for (const item of document.querySelectorAll(".menu-item[data-page]")) {
    if (item.dataset.page === name) item.setAttribute("aria-current", "page");
    else item.removeAttribute("aria-current");
  }
  $("page-title").textContent = tr(PAGES[name], PAGES_EN[name]);
  // 隠れているあいだは幅が測れないので、グラフは表示したときに描き直す
  if (name === "summary" && sumResults.length) {
    renderSummaryChart(sumResults);
    renderSummaryParts(sumResults);
  }
  if (name === "topic" && topResults.length) {
    renderSummaryChart(topResults, "top");
    renderSummaryParts(topResults, "top", TOPIC_PARTS);
  }
  if (name === "repeat" && repDays.length) renderSummaryChart(repDays, "rep", REPEAT_UNIT);
}
for (const item of document.querySelectorAll(".menu-item[data-page]")) {
  item.addEventListener("click", () => {
    const name = item.dataset.page;
    history.replaceState(null, "", name === "home" ? location.pathname + location.search : "#" + name);
    showPage(name);
    setMenu(false);
    window.scrollTo(0, 0);
  });
}
// パスワード再設定のリンク (#...type=recovery) のときは、ページの切り替えに使わない
export const pageFromHash = () => (/type=recovery/.test(location.hash) ? "home" : location.hash.slice(1));
showPage(pageFromHash());
window.addEventListener("hashchange", () => showPage(pageFromHash()));

$("logout").addEventListener("click", async () => {
  setMenu(false);
  try { await api.signOut(); } catch (err) { say($("app-msg"), fe(err), "error"); }
});

// ---------- ログイン状態に合わせて画面を切り替える ----------
api.onAuthChange((user) => {
  if (user && recovering) {
    $("who").textContent = user.email || "";
    show("reset");
  } else if (user) {
    $("who").textContent = user.email || "";
    show("app");
    loadStreak();
  } else {
    show("auth");
  }
});

// 日付をまたいで開きっぱなしだった場合に、戻ってきたとき表示を最新にする
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !$("app").hidden) loadStreak();
});

// 言語を切り替えたら、ログイン画面の文字・今のページ・グラフや一覧を、選んだ言語で作り直す
onLangChange(() => {
  setModeLabels();
  showPage(currentPage);
  if (!$("app").hidden) loadStreak();
});
