// ページの入口: 言語の切り替えを用意し、config.js が設定済みならアプリの画面を読み込む
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "../config.js";
import { applyStaticLang, setLang, show } from "./page/core.js";

for (const b of document.querySelectorAll(".lang-switch button")) {
  b.addEventListener("click", () => setLang(b.dataset.lang));
}
applyStaticLang();

if (SUPABASE_URL.includes("YOUR-PROJECT-REF") || SUPABASE_ANON_KEY === "YOUR-ANON-KEY") {
  show("setup");
} else {
  await import("./page/nav.js");   // ログイン・各ページの部品をまとめて読み込む
}
