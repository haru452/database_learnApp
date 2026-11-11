import { $, adviceBlock, el, fe, say, tr, videoLink } from "./core.js";
import { api } from "./supabase.js";
import { renderSummaryChart } from "./summary.js";

// ---------- リピーティング ----------
export const REPEAT_UNIT = {
  unit: () => "%",
  nth: (i) => tr(`${i}日目`, `Day ${i}`),
  desc: (n, last, best) => tr(`${n}日分の一致率の推移（古い順）。最新は${last}%、最高は${best}%。`,
    `Match rate over ${n} ${n === 1 ? "day" : "days"} (oldest first). Latest: ${last}%, best: ${best}%.`),
};
export const WEAK_LIMIT = 80;
export let repDays = [];   // 日ごとの平均 (古い順) — グラフ用

export const sentenceKey = (t) => t.toLowerCase().replace(/[^a-z0-9\s]/g, "").replace(/\s+/g, " ").trim();
export const average = (xs) => Math.round(xs.reduce((a, b) => a + b, 0) / xs.length);

export function renderRepeat(results) {   // results: 新しい順
  const list = $("rep-list");
  list.replaceChildren();
  $("rep-weak").replaceChildren();
  if (results.length === 0) {
    $("rep-stats").hidden = true;
    $("rep-chart").hidden = true;
    $("rep-weak-sec").hidden = true;
    list.append(el("p", "empty", tr("まだ結果がありません。アプリの「Repeat」で練習すると、ここに一致率が表示されます。",
      "No results yet. Practice in the app\u2019s \u201cRepeat\u201d and your match rate appears here.")));
    repDays = [];
    return;
  }

  // 日ごと (新しい順)
  const byDay = new Map();
  for (const r of results) {
    if (!byDay.has(r.date)) byDay.set(r.date, []);
    byDay.get(r.date).push(r);
  }
  repDays = [...byDay.entries()].reverse().map(([date, rs]) => ({
    date, createdAt: date + "T12:00:00", score: average(rs.map((r) => r.accuracy)), topic: tr(`${rs.length}文`, `${rs.length} ${rs.length === 1 ? "sentence" : "sentences"}`),
  }));

  const box = $("rep-stats");
  box.replaceChildren();
  for (const [label, value] of [
    [tr("練習した日", "Days practiced"), tr(`${repDays.length}日`, String(repDays.length))],
    [tr("平均", "Average"), `${average(results.map((r) => r.accuracy))}%`],
    [tr("最新の日", "Latest day"), `${repDays[repDays.length - 1].score}%`],
    [tr("いちばん良い日", "Best day"), `${Math.max(...repDays.map((d) => d.score))}%`],
  ]) {
    const tile = el("div", "stat");
    tile.append(el("div", "lbl", label), el("div", "val", value));
    box.append(tile);
  }
  box.hidden = false;
  renderSummaryChart(repDays, "rep", REPEAT_UNIT);

  // 苦手な文: 文ごとに一番新しい結果が 80% 未満
  const seen = new Map();
  for (const r of results) {
    if (r.mode === "shadow") continue;   // シャドーイングの文はリピーティングに出さない
    const k = sentenceKey(r.sentence);
    if (!seen.has(k)) seen.set(k, { latest: r, times: 0 });
    seen.get(k).times++;
  }
  const weak = [...seen.values()].filter((w) => w.latest.accuracy < WEAK_LIMIT);
  for (const w of weak) {
    const row = el("div", "entry weak-row");
    row.append(el("span", "acc", `${w.latest.accuracy}%`), el("span", "text", w.latest.sentence),
               el("span", "times", tr(`${w.times}回`, `${w.times}\u00d7`)));
    $("rep-weak").append(row);
  }
  $("rep-weak-sec").hidden = weak.length === 0;

  // 日ごとの結果
  for (const [date, rs] of byDay) {
    list.append(el("div", "day", `${date}  ·  ${tr("平均", "avg.")} ${average(rs.map((r) => r.accuracy))}%`));
    const card = el("div", "entry");
    for (const r of rs) {
      const row = el("div", "rep-row");
      const shadow = r.mode === "shadow";
      row.append(el("span", "acc" + (r.accuracy < WEAK_LIMIT ? " low" : ""), `${r.accuracy}%`),
                 shadow ? videoLink(r.video_id, r.video_title, tr("シャドーイング", "Shadowing")) : el("span", "text", r.sentence));
      if (shadow) row.append(el("span", "mode", tr("シャドー", "Shadow")));
      card.append(row);
      const advice = shadow ? adviceBlock(r.advice) : null;   // シャドーイングは Gemini のアドバイスも見せる
      if (advice) card.append(advice);
    }
    list.append(card);
  }
}

export async function loadRepeat() {
  say($("rep-msg"), "");
  try {
    renderRepeat(await api.getRepeatResults());
  } catch (err) {
    say($("rep-msg"), fe(err), "error");
  }
}
