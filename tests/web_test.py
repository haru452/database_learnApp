"""
Web ページのテスト (Supabase はダミーに差し替える)。
  python3 tests/web_test.py
最後に "ALL WEB TESTS PASSED" と出れば成功。
必要なもの: playwright (Chromium)。
"""
import asyncio
import datetime
import http.server
import json
import os
import socketserver
import sys
import threading

from playwright.async_api import async_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Quiet(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def log_message(self, *a):
        pass


srv = socketserver.TCPServer(("127.0.0.1", 0), Quiet)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

TODAY = (datetime.datetime.now() - datetime.timedelta(hours=3)).date()


def day(n):
    return (TODAY + datetime.timedelta(days=n)).isoformat()


ACTIVITY = [
    {"day": day(0), "diary": True, "summary": True, "topic": True, "repeat": True},     # 金 (4つ全部)
    {"day": day(-1), "diary": True, "summary": False, "topic": True, "repeat": False},  # 銅 (2種類)
    {"day": day(-2), "diary": False, "summary": False, "topic": True, "repeat": False}, # 緑 (お題だけ)
    {"day": day(-3), "diary": True, "summary": False, "topic": False, "repeat": False}, # オレンジ
    {"day": day(-4), "diary": True, "summary": True, "topic": True, "repeat": False},   # 銀 (3種類)
    {"day": day(-5), "diary": False, "summary": False, "topic": False, "repeat": True}, # ピンク (リピーティングだけ)
]

XSS = '<img src=x onerror="window.__xss=1">'
TOPICS = [
    {"id": 3, "entry_date": day(0), "created_at": day(0) + "T03:00:00Z", "kind": "exam",
     "topic": "Is working from home better?", "time_limit_seconds": 60, "score": 72,
     "content_score": 30, "organization_score": 22, "language_score": 20,
     "transcript": "i think home is better", "corrected": "I think home is better. " + XSS,
     "natural_version": "Honestly, I prefer working from home.", "good_points": "- clear opinion",
     "fix_points": "- add an example", "phrases": "In my opinion\nFor example\nOn the other hand",
     "read_aloud_accuracy": 88},
    {"id": 2, "entry_date": day(-1), "created_at": day(-1) + "T03:00:00Z", "kind": "daily",
     "topic": "Describe your weekend.", "time_limit_seconds": 45, "score": 60,
     "content_score": 25, "organization_score": 18, "language_score": 17,
     "transcript": "", "corrected": "", "natural_version": "", "good_points": "", "fix_points": "",
     "phrases": "", "read_aloud_accuracy": None},
    {"id": 1, "entry_date": day(-2), "created_at": day(-2) + "T03:00:00Z", "kind": "work",
     "topic": "Introduce yourself.", "time_limit_seconds": 60, "score": 51,
     "content_score": 20, "organization_score": 16, "language_score": 15,
     "transcript": "", "corrected": "", "natural_version": "", "good_points": "", "fix_points": "",
     "phrases": "", "read_aloud_accuracy": None},
]


def ex(wrong, fixed, source):
    return {"wrong": wrong, "fixed": fixed, "source": source, "date": day(0)}


MISTAKES = [
    {"type": "tense", "count": 5, "previous_count": 2, "examples": [ex("I go yesterday", "I went yesterday", "topic")]},
    {"type": "article", "count": 4, "previous_count": 6, "examples": [ex("a apple", "an apple", "diary")]},
    {"type": "plural", "count": 3, "previous_count": 3, "examples": [ex("two cat", "two cats", "summary")]},
    {"type": "preposition", "count": 2, "previous_count": 0, "examples": [ex("in Monday", "on Monday", "diary")]},
    {"type": "word_order", "count": 1, "previous_count": 0, "examples": [ex("always I", "I always", "diary")]},
    {"type": "other", "count": 1, "previous_count": 1, "examples": [ex(XSS, "x", "diary")]},
]

def rr(i, d, sentence, acc):
    return {"id": i, "entry_date": day(d), "created_at": day(d) + "T03:00:00Z", "sentence": sentence,
            "heard": sentence.lower(), "accuracy": acc, "replays": 1, "source": "tatoeba", "voice": "human"}


REPEAT = [   # 新しい順 (サーバーと同じ)
    dict(rr(7, 0, "", 40), mode="shadow", source="bbc"),   # シャドーは点数だけ (英文なし)。苦手な文に入れない
    rr(6, 0, "Could you send me the file?", 90),     # 前は 60% → 今は 90% なので苦手ではない
    rr(5, 0, "I have lived here for three years.", 70),
    rr(4, -1, XSS + " is not a tag.", 50),
    rr(3, -1, "Could you send me the file?", 60),
    rr(2, -1, "She cooked dinner for us.", 100),
    rr(1, -5, "I have lived here for three years.", 40),
]

SUMMARY = [
    {"id": 1, "entry_date": day(0), "created_at": day(0) + "T03:00:00Z", "video_id": "abcdefghijk",
     "video_title": "Video", "time_limit_seconds": 60, "score": 70, "content_score": 35,
     "organization_score": 18, "language_score": 17, "transcript": "t", "reference_summary": "r",
     "good_points": "g", "missed_points": "m", "language_feedback": "l", "improved_summary": "i"},
]

FAKE = """
const DATA = %s;
export function createClient() {
  const L = []; const user = { id: "u1", email: "me@example.com" };
  setTimeout(() => L.forEach((cb) => cb("SIGNED_IN", { user })), 20);
  return {
    auth: {
      onAuthStateChange: (cb) => { L.push(cb); return { data: { subscription: { unsubscribe() {} } } }; },
      getSession: async () => ({ data: { session: { user } }, error: null }),
      signOut: async () => ({ error: null }),
    },
    rpc: async (name, args) => {
      window.__calls = (window.__calls || []).concat([[name, args]]);
      if (name === "get_my_streak") return { data: [{ streak: 4, last_date: DATA.today, studied_today: true, best_streak: 9 }], error: null };
      if (name === "get_my_activity_days") return { data: DATA.activity, error: null };
      if (name === "get_my_topic_results") return { data: DATA.topics, error: null };
      if (name === "get_my_mistake_stats") return { data: args.p_days === 90 ? DATA.mistakes.map((m) => ({ ...m, previous_count: null })) : DATA.mistakes, error: null };
      if (name === "get_my_summary_results") return { data: DATA.summary, error: null };
      if (name === "get_my_repeat_results") return { data: DATA.repeat, error: null };
      return { data: [], error: null };
    },
  };
}
""" % json.dumps({"today": day(0), "activity": ACTIVITY, "topics": TOPICS, "mistakes": MISTAKES, "summary": SUMMARY, "repeat": REPEAT})

failures = []


def check(ok, what):
    if not ok:
        failures.append(what)
        print("FAILED:", what)


async def open_page(browser, scheme):
    page = await browser.new_page(viewport={"width": 390, "height": 844}, color_scheme=scheme)
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    await page.route("https://esm.sh/**", lambda r: r.fulfill(body=FAKE, content_type="application/javascript"))
    await page.route("**/config.js", lambda r: r.fulfill(
        body='export const SUPABASE_URL="https://x.supabase.co";export const SUPABASE_ANON_KEY="k";',
        content_type="application/javascript"))
    await page.goto(f"http://127.0.0.1:{PORT}/index.html")
    await page.wait_for_selector("#app:not([hidden])", timeout=5000)
    await page.wait_for_selector(".cal-day.on", timeout=5000)
    return page, errors


async def visible_pages(page):
    return await page.evaluate("[...document.querySelectorAll('.page')].filter(p => !p.hidden).map(p => p.dataset.page)")


async def go(page, name):
    await page.click("#menu-btn")
    await page.wait_for_timeout(250)
    await page.click(f".menu-item[data-page={name}]")
    await page.wait_for_timeout(300)


async def run(browser, scheme):
    page, errors = await open_page(browser, scheme)

    # カレンダー
    check(await page.locator(".cal-day.gold").count() == 1, f"{scheme}: one gold (4 kinds) day")
    check(await page.locator(".cal-day.silver").count() == 1, f"{scheme}: one silver (3 kinds) day")
    check(await page.locator(".cal-day.bronze").count() == 1, f"{scheme}: one bronze (2 kinds) day")
    check(await page.locator(".cal-day.both").count() == 0, f"{scheme}: no purple any more")
    check(await page.locator(".cal-day.repeat").count() == 1, f"{scheme}: one repeat-only (pink) day")
    check(await page.locator(".cal-day.topic").count() == 1, f"{scheme}: one topic-only day")
    check(await page.locator(".cal-day.diary").count() == 1, f"{scheme}: one diary-only day")
    diary_color = await page.evaluate("getComputedStyle(document.querySelector('.cal-day.diary')).getPropertyValue('--flame').trim()")
    check(diary_color == "#e03131", f"{scheme}: diary flame is red ({diary_color})")
    diary_dot = await page.evaluate("[...document.querySelectorAll('.cal-legend span')].find(s => s.textContent === '日記').style.getPropertyValue('--c')")
    check(diary_dot == "#e03131", f"{scheme}: diary legend dot is red ({diary_dot})")
    legend = await page.inner_text(".cal-legend")
    check(all(w in legend for w in ("お題", "リピーティング", "2種類", "3種類", "4つ全部")), f"{scheme}: legend {legend}")
    await page.screenshot(path=f"/tmp/web_home_{scheme}.png")

    # メニュー
    items = await page.locator(".menu-item[data-page]").all_text_contents()  # メニューは閉じている (非表示) ので textContent で読む
    check("お題スピーキング" in items and "よくあるミス" in items, f"{scheme}: menu has the two new pages")
    check("リピーティング" in items and items.index("リピーティング") == items.index("お題スピーキング") + 1,
          f"{scheme}: menu has repeat after topic {items}")

    # お題スピーキング
    await go(page, "topic")
    check(await visible_pages(page) == ["topic"], f"{scheme}: only topic page visible")
    check(page.url.endswith("#topic"), f"{scheme}: url #topic")
    # 使い方 (たたんである。開くと手順が読める)
    howto = page.locator("#top-howto")
    check(await howto.count() == 1 and await howto.get_attribute("open") is None, f"{scheme}: topic how-to exists and starts closed")
    await howto.locator("summary").click()
    howto_text = await howto.inner_text()
    for word in ("New Topic", "Start now", "Finish", "Retry", "Read aloud", "Pronunciation check", "Next", "Think Seconds"):
        check(word in howto_text, f"{scheme}: how-to mentions {word}")
    check(await howto.locator("ol > li").count() >= 6, f"{scheme}: how-to has the steps")
    await page.screenshot(path=f"/tmp/web_topic_howto_{scheme}.png", full_page=True)
    await howto.locator("summary").click()
    stats = await page.locator("#top-stats .val").all_inner_texts()
    check(stats == ["3回", "72", "61", "72"], f"{scheme}: topic stats {stats}")
    check(await page.locator("#top-svg circle.dot").count() >= 3, f"{scheme}: topic chart has 3 points")
    check(await page.locator("#top-list .entry").count() == 3, f"{scheme}: topic list has 3 entries")
    await page.locator("#top-list details").first.click()
    detail = await page.locator("#top-list details").first.inner_text()
    check("In my opinion" in detail and "88%" in detail, f"{scheme}: topic details show phrases and read-aloud")
    check(await page.evaluate("window.__xss") is None, f"{scheme}: no script injection in topic list")
    meters = await page.locator("#top-meters .val").all_inner_texts()
    check(len(meters) == 3 and meters[0].endswith("/ 40") and meters[1].endswith("/ 30"), f"{scheme}: topic meters use 40/30/30 {meters}")
    await page.screenshot(path=f"/tmp/web_topic_{scheme}.png", full_page=True)

    # よくあるミス
    await go(page, "mistakes")
    check(await visible_pages(page) == ["mistakes"], f"{scheme}: only mistakes page visible")
    check(page.url.endswith("#mistakes"), f"{scheme}: url #mistakes")
    rows = page.locator("#mis-list .mis-row")
    check(await rows.count() == 6, f"{scheme}: 6 mistake rows")
    names = await page.locator("#mis-list .mis-row .name").all_inner_texts()
    check(names[0].startswith("時制") and names[1].startswith("冠詞"), f"{scheme}: sorted by count {names[:2]}")
    check(await page.locator("#mis-list .mis-row.top").count() == 5, f"{scheme}: top 5 highlighted")
    check(await page.locator("#mis-list .mis-row").nth(0).locator(".trend.up").count() == 1, f"{scheme}: tense up")
    check(await page.locator("#mis-list .mis-row").nth(1).locator(".trend.down").count() == 1, f"{scheme}: article down")
    check(await page.locator("#mis-list .mis-row").nth(2).locator(".trend").count() == 0, f"{scheme}: plural no arrow")
    await rows.nth(0).locator("summary").click()
    ex_text = await rows.nth(0).inner_text()
    check("I go yesterday" in ex_text and "I went yesterday" in ex_text and "お題" in ex_text, f"{scheme}: example with source")
    await rows.nth(5).locator("summary").click()
    check(await page.evaluate("window.__xss") is None, f"{scheme}: no script injection in mistakes")
    for days in (7, 30, 90):
        await page.click(f"#mis-period button[data-days='{days}']")
        await page.wait_for_timeout(150)
    await page.wait_for_timeout(200)
    check(await page.locator("#mis-list .mis-row").count() == 6, f"{scheme}: 90 days still lists rows")
    check(await page.locator("#mis-list .trend").count() == 0, f"{scheme}: 90 days hides trend arrows (no previous data)")
    calls = [c[1]["p_days"] for c in await page.evaluate("window.__calls") if c[0] == "get_my_mistake_stats"]
    check(calls[-3:] == [7, 30, 90], f"{scheme}: period buttons call p_days {calls}")
    await page.screenshot(path=f"/tmp/web_mistakes_{scheme}.png", full_page=True)

    # リピーティング
    await go(page, "repeat")
    check(await visible_pages(page) == ["repeat"], f"{scheme}: only repeat page visible")
    check(page.url.endswith("#repeat"), f"{scheme}: url #repeat")
    rstats = await page.locator("#rep-stats .val").all_inner_texts()
    check(rstats == ["3日", "64%", "67%", "70%"], f"{scheme}: repeat stats count shadow too {rstats}")
    check(await page.locator("#rep-svg circle.dot").count() >= 3, f"{scheme}: repeat chart has a point per day")
    weak = await page.locator("#rep-weak .weak-row").all_inner_texts()
    check(len(weak) == 2 and "I have lived here" in weak[0] and "70%" in weak[0] and "2回" in weak[0],
          f"{scheme}: weak sentences (latest < 80%) {weak}")
    check(not any("Could you send" in w for w in weak), f"{scheme}: improved sentence not weak")
    check(not any(w.startswith("40%") for w in weak), f"{scheme}: shadowing score not in weak sentences {weak}")
    shadow_row = await page.locator("#rep-list .rep-row", has=page.locator(".mode")).inner_text()
    check("40%" in shadow_row and "シャドーイング" in shadow_row,
          f"{scheme}: shadow row shows score and a label instead of text {shadow_row!r}")
    marks = await page.locator("#rep-list .rep-row .mode").all_inner_texts()
    check(marks == ["シャドー"], f"{scheme}: shadow mark on the shadowing row only {marks}")
    check(await page.locator("#rep-list .day").count() == 3, f"{scheme}: results grouped by day")
    check(await page.evaluate("window.__xss") is None, f"{scheme}: no script injection in repeat page")
    rhow = page.locator("#rep-howto")
    check(await rhow.get_attribute("open") is None, f"{scheme}: repeat how-to starts closed")
    await rhow.locator("summary").click()
    rhow_text = await rhow.inner_text()
    for word in ("Start", "Again", "Slow", "Speak", "Next", "80%", "Shadowing", "イヤホン", "YouTube", "Search", "アドバイス"):
        check(word in rhow_text, f"{scheme}: repeat how-to mentions {word}")
    check("BBC" not in rhow_text, f"{scheme}: repeat how-to no longer mentions BBC")
    for word in ():
        check(word in rhow_text, f"{scheme}: repeat how-to mentions {word}")
    await page.screenshot(path=f"/tmp/web_repeat_{scheme}.png", full_page=True)

    # 要約練習のページ (今まで通り)
    await go(page, "summary")
    check(await page.locator("#sum-list .entry").count() == 1, f"{scheme}: summary list still works")
    sum_meters = await page.locator("#sum-meters .val").all_inner_texts()
    check(len(sum_meters) == 3 and sum_meters[0].endswith("/ 50"), f"{scheme}: summary meters keep 50/25/25 {sum_meters}")

    check(errors == [], f"{scheme}: console errors {errors}")
    await page.close()


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        for scheme in ("light", "dark"):
            await run(browser, scheme)
        await browser.close()
    if failures:
        print(len(failures), "web test(s) failed")
        sys.exit(1)
    print("ALL WEB TESTS PASSED")


asyncio.run(main())
