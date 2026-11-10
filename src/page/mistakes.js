import { $, el, fe, lang, say, tr } from "./core.js";
import { api, supabase } from "./supabase.js";
import { createPracticeLogs } from "../practice-logs.js";
import { groupWeakSounds } from "../weak-sounds.js";

// ---------- よくあるミス ----------
export const MISTAKE_LABELS = {
  article: "冠詞 (a / the)", tense: "時制", preposition: "前置詞", agreement: "主語と動詞の一致",
  plural: "単数・複数", verb_form: "動詞の形 (to / -ing)", word_order: "語順", word_choice: "単語の選び方",
  missing_word: "抜けた語", other: "その他",
};
export const MISTAKE_LABELS_EN = {
  article: "Articles (a / the)", tense: "Tense", preposition: "Prepositions", agreement: "Subject-verb agreement",
  plural: "Singular / plural", verb_form: "Verb forms (to / -ing)", word_order: "Word order", word_choice: "Word choice",
  missing_word: "Missing words", other: "Other",
};
export const mistakeLabel = (t) => (lang === "en" ? MISTAKE_LABELS_EN : MISTAKE_LABELS)[t] || t;
export const sourceLabel = (k) => (lang === "en" ? { diary: "diary", summary: "summary", topic: "topic" }
  : { diary: "日記", summary: "要約", topic: "お題" })[k] || k;
export let misDays = 30;

export function renderMistakes(stats) {
  const list = $("mis-list");
  list.replaceChildren();
  const rows = stats.slice().sort((a, b) => b.count - a.count || (b.previousCount ?? 0) - (a.previousCount ?? 0));
  if (rows.length === 0) {
    list.append(el("p", "empty", tr("この期間のミスはまだありません。アプリで添削すると、ここに種類ごとの回数が出ます。",
      "No mistakes in this period yet. Once you correct something in the app, counts by type appear here.")));
    return;
  }
  const max = Math.max(1, ...rows.map((r) => r.count));
  rows.forEach((r, i) => {
    const row = el("details", "mis-row" + (i < 5 && r.count > 0 ? " top" : ""));
    const sum = el("summary");
    const bar = el("div", "bar");
    const fill = el("span");
    fill.style.width = `${(r.count / max) * 100}%`;
    bar.append(fill);
    const cnt = el("span", "cnt", tr(`${r.count}回`, `${r.count}\u00d7`));
    if (r.previousCount != null && r.count !== r.previousCount) {   // 90 日表示では前の期間のデータが無いので null
      const up = r.count > r.previousCount;
      const trend = el("span", up ? "trend up" : "trend down", up ? "↑" : "↓");
      trend.title = tr(`前の${misDays}日: ${r.previousCount}回`, `Previous ${misDays} days: ${r.previousCount}`);
      cnt.append(trend);
    }
    sum.append(el("span", "name", mistakeLabel(r.type)), bar, cnt);
    row.append(sum);

    const ul = el("ul", "mis-ex");
    for (const e of r.examples) {
      const li = el("li");
      li.append(el("span", "wrong", e.wrong), document.createTextNode(" → "), el("span", "", e.fixed),
                el("span", "src", sourceLabel(e.source)));
      ul.append(li);
    }
    if (r.examples.length === 0) ul.append(el("li", "", tr("この期間の例はありません。", "No examples in this period.")));
    row.append(ul);
    list.append(row);
  });
}

// ---------- 苦手な発音 (よくあるミスの期間ボタンに合わせる) ----------
export const SOUND_LABELS = {
  th: "TH の音", r_l: "R と L", v_b: "V と B", f_h: "F と H", s_sh: "S と SH", vowel: "あいまいな母音",
  long_short: "長い母音と短い母音", final_consonant: "語尾の子音", extra_vowel: "余計な母音 (カタカナ発音)", stress: "強勢・リズム",
};
export const SOUND_LABELS_EN = {
  th: "TH", r_l: "R / L", v_b: "V / B", f_h: "F / H", s_sh: "S / SH", vowel: "Vowels (\u00e6 \u028c \u0251 \u0259)",
  long_short: "Long / short vowels", final_consonant: "Final consonants", extra_vowel: "Extra vowels", stress: "Word stress",
};
export const soundLabel = (s) => s.sound === "other"
  ? tr(`その他: ${s.label}`, `Other: ${s.label}`)
  : (lang === "en" ? SOUND_LABELS_EN : SOUND_LABELS)[s.sound] || s.sound;

export function renderWeakSounds(rows) {
  const list = $("snd-list");
  list.replaceChildren();
  if (rows.length === 0) {
    list.append(el("p", "empty", tr("発音チェックや言い直し・リピーティングをすると、ここに苦手な発音が出ます。",
      "Do pronunciation checks, read-aloud or repeating practice, and your weak sounds appear here.")));
    return;
  }
  const groups = groupWeakSounds(rows);
  const max = Math.max(1, ...groups.map((g) => g.points));
  // 名前・棒・点 (前の期間より増えた / 減ったら矢印) の 1 行。tag は "div" か、押して開く行の "summary"
  const head = (tag, name, points, previousPoints) => {
    const h = el(tag, "head");
    const bar = el("div", "bar");
    const fill = el("span");
    fill.style.width = `${(points / max) * 100}%`;
    bar.append(fill);
    const cnt = el("span", "cnt", tr(`${points}点`, `${points} pts`));
    if (previousPoints != null && points !== previousPoints) {   // 90 日表示では null
      const up = points > previousPoints;
      const trend = el("span", up ? "trend up" : "trend down", up ? "↑" : "↓");
      trend.title = tr(`前の${misDays}日: ${previousPoints}点`, `Previous ${misDays} days: ${previousPoints} pts`);
      cnt.append(trend);
    }
    h.append(el("span", "name", name), bar, cnt);
    return h;
  };
  for (const g of groups) {
    if (g.kind === "one") {
      const r = g.row;
      const row = el("div", "snd-row");
      row.append(head("div", soundLabel(r), r.points, r.previousPoints));
      if (r.words.length > 0) row.append(el("div", "words", tr("例: ", "e.g. ") + r.words.join(", ")));
      list.append(row);
      continue;
    }
    // その他: まとめた 1 行。押すと音ごとの点と例を出す
    const row = el("details", "snd-row snd-other");
    row.append(head("summary", tr(`その他 (${g.items.length} 種類)`, `Other (${g.items.length})`), g.points, g.previousPoints));
    const ul = el("ul", "snd-sub");
    for (const r of g.items) {
      const li = el("li");
      li.append(el("span", "sub-name", r.label), el("span", "sub-cnt", tr(`${r.points}点`, `${r.points} pts`)));
      if (r.words.length > 0) li.append(el("span", "words", tr("例: ", "e.g. ") + r.words.join(", ")));
      ul.append(li);
    }
    row.append(ul);
    list.append(row);
  }
}

export async function loadWeakSounds() {
  say($("snd-msg"), "");
  try {
    renderWeakSounds(await api.getWeakSounds(misDays));
  } catch (err) {
    // sounds.sql を実行していないなど: 欄は空のまま、理由だけ出す
    $("snd-list").replaceChildren();
    say($("snd-msg"), fe(err), "error");
  }
}

export const practiceLogs = createPracticeLogs({
  supabase, $, el, tr, say, fe, soundName: (code) => soundLabel({ sound: code, label: "" }),
});

export async function loadMistakes() {
  loadWeakSounds();
  practiceLogs.load();
  say($("mis-msg"), "");
  for (const b of $("mis-period").querySelectorAll("button")) {
    b.setAttribute("aria-pressed", String(Number(b.dataset.days) === misDays));
  }
  try {
    renderMistakes(await api.getMistakeStats(misDays));
  } catch (err) {
    say($("mis-msg"), fe(err), "error");
  }
}

for (const b of $("mis-period").querySelectorAll("button")) {
  b.addEventListener("click", () => {
    misDays = Number(b.dataset.days);
    loadMistakes();
  });
}
