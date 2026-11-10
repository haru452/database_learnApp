// 「ミス」のページの 2 つの一覧。どちらもまとめずに、1 回ずつ新しい順に出す。
//  - 単語の発音 (vocab_pron.sql): 単語帳で苦手な音 (th・R と L など) があった単語。音のボタンで絞れる
//  - 短い答え (answer.sql): 短い答えの練習の問題・自分の答え・正解。「間違えただけ」で絞れる
//  - カラオケ (karaoke.sql): 歌った曲・点数・うまく発音できなかった単語と音。1 曲ずつ
// 表が無い (SQL を流していない) ときは、欄に理由だけ出す。

const LIMIT = 200;

export function createPracticeLogs({ supabase, $, el, tr, say, fe, soundName }) {
  let pron = [];
  let pronSound = "all";
  let answers = [];
  let wrongOnly = false;
  let songs = [];

  const when = (iso) => {
    const d = new Date(iso);
    const p = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  };

  function filterButtons(box, items, pressed, onPick) {
    box.replaceChildren();
    for (const [key, text] of items) {
      const b = el("button", "", text);
      b.type = "button";
      b.setAttribute("aria-pressed", String(key === pressed));
      b.addEventListener("click", () => onPick(key));
      box.append(b);
    }
  }

  // ---------------- 単語の発音 ----------------
  function renderPron() {
    const sounds = [...new Set(pron.flatMap((r) => r.sounds))];
    if (pronSound !== "all" && !sounds.includes(pronSound)) pronSound = "all";
    filterButtons($("vpron-filter"), [["all", tr("すべて", "All")], ...sounds.map((s) => [s, soundName(s)])], pronSound,
      (key) => { pronSound = key; renderPron(); });

    const list = $("vpron-list");
    list.replaceChildren();
    const rows = pronSound === "all" ? pron : pron.filter((r) => r.sounds.includes(pronSound));
    if (rows.length === 0) {
      list.append(el("p", "empty", tr("単語帳で発音の採点をすると、苦手な音があった単語がここに出ます。",
        "Score your pronunciation in the vocabulary book, and words with a weak sound appear here.")));
      return;
    }
    for (const r of rows) {
      const row = el("div", "log-row");
      const head = el("div", "head");
      head.append(el("span", "word", r.word));
      for (const s of r.sounds) head.append(el("span", "chip", soundName(s)));
      head.append(el("span", "when", when(r.taken_at)));
      row.append(head);
      if (r.heard) row.append(el("div", "sub", tr("聞こえた音: ", "Heard: ") + r.heard));
      if (r.advice) row.append(el("div", "sub", r.advice));
      list.append(row);
    }
  }

  async function loadPron() {
    say($("vpron-msg"), "");
    const { data, error } = await supabase.from("vocab_pron_logs")
      .select("word, sounds, rating, advice, heard, taken_at")
      .order("taken_at", { ascending: false }).order("id", { ascending: false }).limit(LIMIT);
    if (error) {
      $("vpron-list").replaceChildren();
      say($("vpron-msg"), fe(error), "error");
      return;
    }
    pron = data || [];
    renderPron();
  }

  // ---------------- 短い答え ----------------
  function renderAnswers() {
    filterButtons($("ans-filter"), [[false, tr("すべて", "All")], [true, tr("間違えただけ", "Wrong only")]], wrongOnly,
      (key) => { wrongOnly = key; renderAnswers(); });
    const list = $("ans-list");
    list.replaceChildren();
    const rows = wrongOnly ? answers.filter((r) => !r.correct) : answers;
    if (rows.length === 0) {
      list.append(el("p", "empty", wrongOnly
        ? tr("間違えた問題はありません。", "No wrong answers.")
        : tr("短い答えの練習 (Modes → Answer) をすると、ここに結果が出ます。",
             "Do the short-answer practice (Modes → Answer), and your results appear here.")));
      return;
    }
    for (const r of rows) {
      const row = el("div", "log-row");
      const head = el("div", "head");
      head.append(el("span", r.correct ? "mark ok" : "mark ng", r.correct ? tr("正解", "Correct") : tr("不正解", "Wrong")));
      head.append(el("span", "q", r.question));
      head.append(el("span", "when", when(r.taken_at)));
      row.append(head);
      row.append(el("div", "sub", tr("正解: ", "Answer: ") + (r.answers || []).join(" / ")));
      row.append(el("div", "sub", tr("あなた: ", "You: ") + (r.heard || "-")));
      list.append(row);
    }
  }

  async function loadAnswers() {
    say($("ans-msg"), "");
    const { data, error } = await supabase.from("short_answer_results")
      .select("question, answers, heard, correct, taken_at")
      .order("taken_at", { ascending: false }).order("id", { ascending: false }).limit(LIMIT);
    if (error) {
      $("ans-list").replaceChildren();
      say($("ans-msg"), fe(error), "error");
      return;
    }
    answers = data || [];
    renderAnswers();
  }

  // ---------------- カラオケ ----------------
  function renderKaraoke() {
    const list = $("karaoke-list");
    list.replaceChildren();
    if (songs.length === 0) {
      list.append(el("p", "empty", tr("カラオケ (Modes → Karaoke) で歌うと、ここに結果が出ます。",
        "Sing in Karaoke (Modes → Karaoke), and your results appear here.")));
      return;
    }
    for (const r of songs) {
      const row = el("div", "log-row");
      const head = el("div", "head");
      head.append(el("span", "word", r.artist ? `${r.title} / ${r.artist}` : r.title));
      head.append(el("span", "chip", tr(`${r.score} 点`, `${r.score} / 100`)));
      head.append(el("span", "when", when(r.taken_at)));
      row.append(head);
      const words = (r.items || []).flatMap((line) => (line.words || []));
      if (words.length === 0) {
        row.append(el("div", "sub", tr("言えなかった単語はありません。", "No hard words.")));
      } else {
        const chips = el("div", "sub");
        for (const w of words) chips.append(el("span", "chip", `${w.word} (${soundName(w.sound)})`));
        row.append(chips);
      }
      list.append(row);
    }
  }

  async function loadKaraoke() {
    say($("karaoke-msg"), "");
    const { data, error } = await supabase.from("karaoke_results")
      .select("title, artist, score, items, taken_at")
      .order("taken_at", { ascending: false }).order("id", { ascending: false }).limit(LIMIT);
    if (error) {
      $("karaoke-list").replaceChildren();
      say($("karaoke-msg"), fe(error), "error");
      return;
    }
    songs = data || [];
    renderKaraoke();
  }

  return {
    load: () => Promise.all([loadPron(), loadAnswers(), loadKaraoke()]),
    rerender: () => { renderPron(); renderAnswers(); renderKaraoke(); },   // 言語を切り替えたとき
  };
}
