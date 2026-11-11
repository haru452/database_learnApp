// ページ全体で使う小さな部品と、表示する言語 (日本語 / English)
import { friendlyError } from "../streak-client.js";

export const $ = (id) => document.getElementById(id);
export const show = (name) => {
  for (const id of ["loading", "setup", "auth", "reset", "app"]) $(id).hidden = id !== name;
};
export const say = (el, text, kind = "") => { el.textContent = text; el.className = "msg " + kind; };

// 要素を作る。文字は textContent で入れる (HTML として解釈させない)
export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// YouTube の動画へのリンク (新しいタブで開く)。id が無ければ題名だけ
export function videoLink(videoId, title, fallback) {
  const text = title || fallback || "";
  if (!videoId || !/^[A-Za-z0-9_-]{6,20}$/.test(videoId)) return el("span", "text", text);
  const a = el("a", "text video-link", text || videoId);
  a.href = `https://www.youtube.com/watch?v=${videoId}`;
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  return a;
}

// Gemini のアドバイス (改行はそのまま。空なら null)
export function adviceBlock(advice) {
  if (!advice || !advice.trim()) return null;
  const box = el("div", "advice");
  box.append(el("div", "advice-label", tr("Gemini のアドバイス", "Gemini’s advice")), el("div", "advice-text", advice.trim()));
  return box;
}

// ---------- 言語 (日本語 / English)。選んだ言語はこのブラウザに覚えておく ----------
export let lang = "ja";
try { if (localStorage.getItem("lang") === "en") lang = "en"; } catch { /* 保存できない環境では日本語 */ }
export const tr = (ja, en) => (lang === "en" ? en : ja);
export const locale = () => (lang === "en" ? "en-US" : "ja-JP");
export const fe = (err) => friendlyError(err, lang);

// data-en (文字) と data-en-aria (読み上げ用のラベル) を持つ要素を、選んだ言語にする
export function applyStaticLang() {
  document.documentElement.lang = lang;
  document.title = tr("学習ストリーク", "Study Streak");
  for (const n of document.querySelectorAll("[data-en]")) {
    if (n.dataset.ja === undefined) n.dataset.ja = n.textContent;
    n.textContent = lang === "en" ? n.dataset.en : n.dataset.ja;
  }
  for (const n of document.querySelectorAll("[data-en-aria]")) {
    if (n.dataset.jaAria === undefined) n.dataset.jaAria = n.getAttribute("aria-label");
    n.setAttribute("aria-label", lang === "en" ? n.dataset.enAria : n.dataset.jaAria);
  }
  for (const b of document.querySelectorAll(".lang-switch button")) {
    b.setAttribute("aria-pressed", String(b.dataset.lang === lang));
  }
}

let langChanged = null;   // アプリの画面ができたら nav.js が登録する

/** 言語を切り替えたときに、画面を作り直す関数を登録する */
export function onLangChange(fn) { langChanged = fn; }

export function setLang(next) {
  if (next === lang) return;
  lang = next;
  try { localStorage.setItem("lang", lang); } catch { /* 保存できなくても、この画面では切り替える */ }
  applyStaticLang();
  if (langChanged) langChanged();
}
