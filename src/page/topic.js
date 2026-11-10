import { $, el, fe, lang, say, tr } from "./core.js";
import { api } from "./supabase.js";
import { TOPIC_PARTS, formatDateTime, hasParts, partsText, renderSummaryChart, renderSummaryParts, renderSummaryStats } from "./summary.js";

// ---------- お題スピーキング ----------
export const kindLabel = (k) => (lang === "en"
  ? { exam: "Exam", daily: "Daily", work: "Work / interview" }
  : { exam: "試験", daily: "身近な話題", work: "仕事・面接" })[k] || k;
export let topResults = [];   // 古い順

export function renderTopicList() {
  const list = $("top-list");
  list.replaceChildren();
  for (const r of topResults.slice().reverse()) {
    const card = el("div", "entry result");
    card.append(el("div", "meta",
      `${formatDateTime(r.createdAt)}  ·  ${kindLabel(r.kind)}  ·  ${r.timeLimit}${tr("秒", " sec")}`));
    const head = el("div", "head");
    const score = el("div", "score", String(r.score));
    score.append(el("small", "", " / 100"));
    head.append(score, el("span", "", r.topic));
    card.append(head);
    if (hasParts(r, TOPIC_PARTS)) card.append(el("div", "parts-line", partsText(r, TOPIC_PARTS)));

    const details = el("details");
    details.append(el("summary", "", tr("詳しく見る", "Details")));
    for (const [label, text, fix] of [
      [tr("あなたの答え", "Your answer"), r.transcript],
      [tr("良かった点", "Good points"), r.goodPoints],
      [tr("直す点", "Points to fix"), r.fixPoints],
      [tr("添削", "Corrected"), r.corrected, true],
      [tr("自然な言い方", "More natural"), r.natural, true],
      [tr("次に使える表現", "Phrases to use next time"), r.phrases, true],
      [tr("言い直しの一致率", "Read-aloud match rate"), Number.isFinite(r.readAloudAccuracy) ? `${r.readAloudAccuracy}%` : ""],
    ]) {
      if (!text) continue;
      details.append(el("div", fix ? "lbl fix" : "lbl", label), el("p", "", text));
    }
    card.append(details);
    list.append(card);
  }
}

export function renderTopic() {
  if (topResults.length === 0) {
    $("top-stats").hidden = true;
    $("top-chart").hidden = true;
    $("top-parts").hidden = true;
    $("top-list").replaceChildren(
      el("p", "empty", tr("まだ結果がありません。アプリの「Topic」でお題について話すと、ここに点数の推移が表示されます。",
        "No results yet. Speak on a topic in the app\u2019s \u201cTopic\u201d and your score trend appears here.")));
    return;
  }
  renderSummaryStats(topResults, "top");
  renderSummaryChart(topResults, "top");
  renderSummaryParts(topResults, "top", TOPIC_PARTS);
  renderTopicList();
}

export async function loadTopic() {
  say($("top-msg"), "");
  try {
    topResults = (await api.getTopicResults()).reverse();   // 古い順にする
    renderTopic();
  } catch (err) {
    say($("top-msg"), fe(err), "error");
  }
}
