import { $, el, fe, locale, say, tr } from "./core.js";
import { api } from "./supabase.js";
import { topResults } from "./topic.js";
import { REPEAT_UNIT, repDays } from "./repeat.js";

// ---------- 要約練習のスコア (点数の推移) ----------
export const SVG_NS = "http://www.w3.org/2000/svg";
export const LIST_PAGE = 10;
export let sumResults = [];   // 古い順
export let sumShown = LIST_PAGE;

export function svgEl(tag, attrs) {
  const node = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  return node;
}

export function formatDateTime(iso) {
  const d = new Date(iso);
  return isNaN(d) ? "" : d.toLocaleString(locale(), { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

export function formatShortDate(iso) {
  const d = new Date(iso);
  return isNaN(d) ? "" : d.toLocaleDateString(locale(), { month: "numeric", day: "numeric" });
}

export function renderSummaryStats(results, P = "sum") {
  const box = $(P + "-stats");
  box.replaceChildren();
  const scores = results.map((r) => r.score);
  const recent = scores.slice(-5);
  const items = [
    [tr("回数", "Attempts"), tr(`${scores.length}回`, String(scores.length))],
    [tr("最新", "Latest"), String(scores[scores.length - 1])],
    [tr("直近5回の平均", "Last 5 avg."), (recent.reduce((a, b) => a + b, 0) / recent.length).toFixed(0)],
    [tr("最高", "Best"), String(Math.max(...scores))],
  ];
  for (const [label, value] of items) {
    const tile = el("div", "stat");
    tile.append(el("div", "lbl", label), el("div", "val", value));
    box.append(tile);
  }
  box.hidden = false;
}

// グラフの単位と説明文 (要約・お題は 1回ごとの「点」、リピーティングは 1日ごとの「%」)
export const SCORE_UNIT = {
  unit: () => tr("点", " pts"),
  nth: (i) => tr(`${i}回目`, `#${i}`),
  desc: (n, last, best) => tr(`${n}回分の点数の推移（古い順）。最新は${last}点、最高は${best}点。`,
    `Scores over ${n} ${n === 1 ? "attempt" : "attempts"} (oldest first). Latest: ${last}, best: ${best}.`),
};

// 1回ごとの点数を、古い順に左から並べた折れ線グラフ
export function renderSummaryChart(results, P = "sum", U = SCORE_UNIT) {
  const svg = $(P + "-svg");
  const tip = $(P + "-tip");
  svg.replaceChildren();
  tip.hidden = true;
  $(P + "-chart").hidden = false;

  const W = svg.clientWidth || 470;
  const H = 200;
  const m = { left: 30, right: 34, top: 12, bottom: 24 };
  const iw = W - m.left - m.right;
  const ih = H - m.top - m.bottom;
  const n = results.length;
  const x = (i) => m.left + (n === 1 ? iw / 2 : (iw * i) / (n - 1));
  const y = (score) => m.top + ih * (1 - score / 100);
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);

  // 目盛り (0 / 25 / 50 / 75 / 100)
  for (const v of [0, 25, 50, 75, 100]) {
    svg.append(svgEl("line", { class: "grid", x1: m.left, x2: W - m.right, y1: y(v), y2: y(v) }));
    const t = svgEl("text", { class: "tick", x: m.left - 6, y: y(v) + 4, "text-anchor": "end" });
    t.textContent = String(v);
    svg.append(t);
  }

  // 横軸: 最初と最後の日付
  const first = svgEl("text", { class: "tick", x: x(0), y: H - 6, "text-anchor": n === 1 ? "middle" : "start" });
  first.textContent = formatShortDate(results[0].createdAt);
  svg.append(first);
  if (n > 1) {
    const last = svgEl("text", { class: "tick", x: x(n - 1), y: H - 6, "text-anchor": "end" });
    last.textContent = formatShortDate(results[n - 1].createdAt);
    svg.append(last);
  }

  const pts = results.map((r, i) => [x(i), y(r.score)]);
  if (n > 1) {
    const line = pts.map(([px, py], i) => `${i ? "L" : "M"}${px},${py}`).join(" ");
    svg.append(svgEl("path", { class: "area", d: `${line} L${x(n - 1)},${y(0)} L${x(0)},${y(0)} Z` }));
    svg.append(svgEl("path", { class: "line", d: line }));
  }

  // 点は、多すぎなければ全部、多ければ最後だけ
  const dotAll = n <= 40;
  pts.forEach(([px, py], i) => {
    if (dotAll || i === n - 1) svg.append(svgEl("circle", { class: "dot", cx: px, cy: py, r: 4 }));
  });

  // 最新の点数だけ、線の端に表示する
  const endLabel = svgEl("text", { class: "end-label", x: pts[n - 1][0] + 8, y: pts[n - 1][1] + 4 });
  endLabel.textContent = String(results[n - 1].score);
  svg.append(endLabel);

  // ホバー / タップ: いちばん近い回の点数を出す
  const cross = svgEl("line", { class: "cross", y1: m.top, y2: H - m.bottom, visibility: "hidden" });
  const focus = svgEl("circle", { class: "dot", r: 6, visibility: "hidden" });
  svg.append(cross, focus);

  function showAt(clientX) {
    const box = svg.getBoundingClientRect();
    const px = ((clientX - box.left) / box.width) * W;
    const i = n === 1 ? 0 : Math.max(0, Math.min(n - 1, Math.round(((px - m.left) / iw) * (n - 1))));
    const r = results[i];
    const [cx, cy] = pts[i];
    cross.setAttribute("x1", cx);
    cross.setAttribute("x2", cx);
    focus.setAttribute("cx", cx);
    focus.setAttribute("cy", cy);
    cross.setAttribute("visibility", "visible");
    focus.setAttribute("visibility", "visible");

    tip.replaceChildren(
      el("div", "score", `${r.score}${U.unit()}`),
      el("div", "sub", `${formatDateTime(r.createdAt)}  ·  ${U.nth(i + 1)}`),
      el("div", "", r.videoTitle || r.topic || tr("(タイトルなし)", "(no title)")));
    tip.hidden = false;
    const scale = box.width / W;
    const left = cx * scale + 12 + tip.offsetWidth > box.width ? cx * scale - 12 - tip.offsetWidth : cx * scale + 12;
    tip.style.left = `${Math.max(0, left)}px`;
  }

  function hide() {
    cross.setAttribute("visibility", "hidden");
    focus.setAttribute("visibility", "hidden");
    tip.hidden = true;
  }

  svg.onpointermove = (e) => showAt(e.clientX);
  svg.onpointerdown = (e) => showAt(e.clientX);
  svg.onpointerleave = hide;

  const lastScore = results[n - 1].score;
  $(P + "-chart-desc").textContent = U.desc(n, lastScore, Math.max(...results.map((r) => r.score)));
}

// ---------- 項目ごとの点数 (内容 / 構成 / 文法・語彙) ----------
// 項目の名前は、選んだ言語で返す (get name)
export const PART_NAMES = {
  contentScore: ["内容", "Content"], organizationScore: ["構成", "Organization"], languageScore: ["文法・語彙", "Grammar & vocab"],
};
export const part = (key, max, cls, color) => ({
  key, max, cls, color, get name() { return tr(...PART_NAMES[key]); },
});
export const PARTS = [
  part("contentScore", 50, "seg-1", "var(--part-1)"),
  part("organizationScore", 25, "seg-2", "var(--part-2)"),
  part("languageScore", 25, "seg-3", "var(--part-3)"),
];
// お題スピーキングの配分 (内容 40 + 構成 30 + 文法・語彙 30)
export const TOPIC_PARTS = [
  part("contentScore", 40, "seg-1", "var(--part-1)"),
  part("organizationScore", 30, "seg-2", "var(--part-2)"),
  part("languageScore", 30, "seg-3", "var(--part-3)"),
];
export const STACK_COUNT = 20;   // 内訳のグラフに出す回数 (直近)
export const AVERAGE_COUNT = 5;  // 平均を出す回数 (直近)

export const hasParts = (r, parts = PARTS) => parts.every((p) => Number.isFinite(r[p.key]));

export function swatch(color) {
  const s = el("span", "swatch");
  s.style.background = color;
  return s;
}

export function partsText(r, parts = PARTS) {
  return parts.map((p) => `${p.name} ${r[p.key]}/${p.max}`).join("  ·  ");
}

// 直近の平均を、満点に対する割合のバーで表示する (どの項目が弱いかが分かる)
export function renderPartMeters(withParts, P = "sum", parts = PARTS) {
  const box = $(P + "-meters");
  box.replaceChildren();
  const recent = withParts.slice(-AVERAGE_COUNT);
  for (const p of parts) {
    const avg = recent.reduce((a, r) => a + r[p.key], 0) / recent.length;
    const row = el("div", "meter");
    const name = el("div", "name");
    name.append(swatch(p.color), el("span", "", p.name));
    const track = el("div", "track");
    const fill = el("div", "fill");
    fill.style.width = `${(avg / p.max) * 100}%`;
    fill.style.background = p.color;
    track.append(fill);
    row.append(name, track, el("div", "val", `${avg.toFixed(1)} / ${p.max}`));
    box.append(row);
  }
  box.append(el("p", "hint", tr(`直近${recent.length}回の平均`, `Average of the last ${recent.length}`)));
}

// 1回ごとに、3項目を積み上げた棒 (棒の高さ = 合計点)
export function renderPartStack(withParts, P = "sum", parts = PARTS) {
  const results = withParts.slice(-STACK_COUNT);
  const svg = $(P + "-stack-svg");
  const tip = $(P + "-stack-tip");
  svg.replaceChildren();
  tip.hidden = true;

  const legend = $(P + "-legend");
  legend.replaceChildren();
  for (const p of parts) {
    const item = el("span");
    item.append(swatch(p.color), document.createTextNode(tr(`${p.name}（${p.max}点）`, `${p.name} (${p.max})`)));
    legend.append(item);
  }

  const W = svg.clientWidth || 470;
  const H = 200;
  const m = { left: 30, right: 8, top: 10, bottom: 24 };
  const iw = W - m.left - m.right;
  const ih = H - m.top - m.bottom;
  const n = results.length;
  const slot = iw / Math.max(n, 8);               // 回数が少ないときも、棒が太くなりすぎないよう 8 回分の枠は確保する
  const barW = Math.min(24, slot * 0.6);
  const cx = (i) => m.left + slot * (i + 0.5);
  const y = (v) => m.top + ih * (1 - v / 100);
  const GAP = 2;                                  // 項目の間のすき間
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);

  for (const v of [0, 25, 50, 75, 100]) {
    svg.append(svgEl("line", { class: "grid", x1: m.left, x2: W - m.right, y1: y(v), y2: y(v) }));
    const t = svgEl("text", { class: "tick", x: m.left - 6, y: y(v) + 4, "text-anchor": "end" });
    t.textContent = String(v);
    svg.append(t);
  }

  const first = svgEl("text", { class: "tick", x: cx(0), y: H - 6, "text-anchor": "start" });
  first.textContent = formatShortDate(results[0].createdAt);
  svg.append(first);
  if (n > 1) {
    const last = svgEl("text", { class: "tick", x: cx(n - 1), y: H - 6, "text-anchor": "end" });
    last.textContent = formatShortDate(results[n - 1].createdAt);
    svg.append(last);
  }

  const hover = svgEl("rect", { class: "col-hover", y: m.top, width: slot, height: ih, visibility: "hidden" });
  svg.append(hover);

  results.forEach((r, i) => {
    const x0 = cx(i) - barW / 2;
    let base = 0;
    const segs = parts.map((p) => ({ p, from: base, to: (base += r[p.key]) })).filter((s) => s.to > s.from);
    segs.forEach((s, k) => {
      const top = y(s.to);
      const bottom = y(s.from) - (k > 0 ? GAP : 0);
      const h = Math.max(0, bottom - top);
      if (h <= 0) return;
      if (k === segs.length - 1) {
        // いちばん上の項目だけ、上の角を丸くする (下は土台にそろえて四角のまま)
        const rr = Math.min(4, h, barW / 2);
        svg.append(svgEl("path", {
          class: s.p.cls,
          d: `M${x0},${bottom} V${top + rr} Q${x0},${top} ${x0 + rr},${top} H${x0 + barW - rr} ` +
             `Q${x0 + barW},${top} ${x0 + barW},${top + rr} V${bottom} Z`,
        }));
      } else {
        svg.append(svgEl("rect", { class: s.p.cls, x: x0, y: top, width: barW, height: h }));
      }
    });
  });

  // ホバー / タップ: その回の内訳を出す
  function showAt(clientX) {
    const box = svg.getBoundingClientRect();
    const px = ((clientX - box.left) / box.width) * W;
    const i = Math.floor((px - m.left) / slot);
    if (i < 0 || i >= n) { hide(); return; }
    const r = results[i];
    hover.setAttribute("x", m.left + slot * i);
    hover.setAttribute("visibility", "visible");

    tip.replaceChildren(
      el("div", "score", tr(`合計 ${r.score}点`, `Total ${r.score}`)),
      el("div", "sub", formatDateTime(r.createdAt)));
    for (const p of parts.slice().reverse()) {   // 棒と同じ並び (上から)
      const row = el("div", "row");
      row.append(swatch(p.color), el("span", "", `${p.name} ${r[p.key]} / ${p.max}`));
      tip.append(row);
    }
    tip.hidden = false;
    const scale = box.width / W;
    const xs = cx(i) * scale;
    const left = xs + 16 + tip.offsetWidth > box.width ? xs - 16 - tip.offsetWidth : xs + 16;
    tip.style.left = `${Math.max(0, left)}px`;
    tip.style.top = `${$(P + "-legend").offsetHeight}px`;
  }

  function hide() {
    hover.setAttribute("visibility", "hidden");
    tip.hidden = true;
  }

  svg.onpointermove = (e) => showAt(e.clientX);
  svg.onpointerdown = (e) => showAt(e.clientX);
  svg.onpointerleave = hide;

  const avg = (key) => (results.reduce((a, r) => a + r[key], 0) / n).toFixed(1);
  $(P + "-stack-desc").textContent =
    tr(`直近${n}回の内訳（古い順）。平均は `, `Breakdown of the last ${n} (oldest first). Averages: `) +
    parts.map((p) => `${p.name} ${avg(p.key)}/${p.max}`).join(tr("、", ", ")) + tr("。", ".");
}

export function renderSummaryParts(results, P = "sum", parts = PARTS) {
  const withParts = results.filter((r) => hasParts(r, parts));
  $(P + "-parts").hidden = withParts.length === 0;   // 項目別の採点を入れる前の結果しか無い場合は出さない
  if (withParts.length === 0) return;
  renderPartMeters(withParts, P, parts);
  renderPartStack(withParts, P, parts);
}

export function youtubeUrl(videoId) {
  return /^[\w-]{6,20}$/.test(videoId) ? `https://www.youtube.com/watch?v=${videoId}` : "";
}

export function renderSummaryList() {
  const list = $("sum-list");
  list.replaceChildren();
  const newestFirst = sumResults.slice().reverse();
  for (const r of newestFirst.slice(0, sumShown)) {
    const card = el("div", "entry result");
    card.append(el("div", "meta", `${formatDateTime(r.createdAt)}  ·  ${r.timeLimit}${tr("秒", " sec")}`));

    const head = el("div", "head");
    const score = el("div", "score", String(r.score));
    score.append(el("small", "", " / 100"));
    head.append(score);
    const url = youtubeUrl(r.videoId);
    if (url) {
      const a = el("a", "", r.videoTitle || url);
      a.href = url;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      head.append(a);
    } else {
      head.append(el("span", "", r.videoTitle));
    }
    card.append(head);
    if (hasParts(r)) card.append(el("div", "parts-line", partsText(r)));

    const details = el("details");
    details.append(el("summary", "", tr("詳しく見る", "Details")));
    for (const [label, text, fix] of [
      [tr("あなたの要約", "Your summary"), r.transcript],
      [tr("押さえた点", "Points you covered"), r.goodPoints],
      [tr("抜けた点", "Points you missed"), r.missedPoints],
      [tr("文法・言い回し", "Grammar & wording"), r.languageFeedback],
      [tr("お手本の要約", "Model summary"), r.referenceSummary, true],
      [tr("あなたの要約の改善例", "Your summary, improved"), r.improvedSummary, true],
    ]) {
      if (!text) continue;
      details.append(el("div", fix ? "lbl fix" : "lbl", label), el("p", "", text));
    }
    card.append(details);
    list.append(card);
  }
  $("sum-more").hidden = sumShown >= sumResults.length;
}

export function renderSummary() {
  if (sumResults.length === 0) {
    $("sum-stats").hidden = true;
    $("sum-chart").hidden = true;
    $("sum-parts").hidden = true;
    $("sum-more").hidden = true;
    $("sum-list").replaceChildren(
      el("p", "empty", tr("まだ結果がありません。アプリの「Summary」で動画を要約すると、ここに点数の推移が表示されます。",
        "No results yet. Summarize a video in the app\u2019s \u201cSummary\u201d and your score trend appears here.")));
    return;
  }
  renderSummaryStats(sumResults);
  renderSummaryChart(sumResults);
  renderSummaryParts(sumResults);
  renderSummaryList();
}

export async function loadSummary() {
  say($("sum-msg"), "");
  try {
    sumResults = (await api.getSummaryResults()).reverse();   // 古い順にする
    sumShown = LIST_PAGE;
    renderSummary();
  } catch (err) {
    say($("sum-msg"), fe(err), "error");
  }
}

$("sum-more").addEventListener("click", () => {
  sumShown += LIST_PAGE;
  renderSummaryList();
});

// 画面の幅が変わったら、グラフを描き直す
export let resizeTimer;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if ($("app").hidden) return;
    if (sumResults.length) {
      renderSummaryChart(sumResults);
      renderSummaryParts(sumResults);
    }
    if (topResults.length) {
      renderSummaryChart(topResults, "top");
      renderSummaryParts(topResults, "top", TOPIC_PARTS);
    }
    if (repDays.length) renderSummaryChart(repDays, "rep", REPEAT_UNIT);
  }, 150);
});
