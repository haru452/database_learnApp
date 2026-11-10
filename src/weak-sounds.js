// 苦手な発音の一覧: 「その他: ○○」の行を 1 つの「その他」にまとめる (押すと音ごとに開く)。
// rows は getWeakSounds の結果 ({ sound, label, points, previousPoints, words })。
// 返すのは点の多い順の一覧。決まった音は { kind: "one", row }、その他は { kind: "other", points, previousPoints, items }。
export function groupWeakSounds(rows) {
  const others = rows.filter((r) => r.sound === "other");
  const list = rows.filter((r) => r.sound !== "other").map((row) => ({ kind: "one", row, points: row.points }));
  if (others.length > 0) {
    const items = others.slice().sort((a, b) => b.points - a.points);
    const sum = (key) => items.reduce((n, r) => n + (r[key] ?? 0), 0);
    list.push({
      kind: "other",
      points: sum("points"),
      // 前の期間が無い (90 日表示) ときは null
      previousPoints: items.some((r) => r.previousPoints == null) ? null : sum("previousPoints"),
      items,
    });
  }
  // 同じ点なら元の順 (決まった音が先)
  return list.map((g, i) => ({ g, i })).sort((a, b) => b.g.points - a.g.points || a.i - b.i).map((x) => x.g);
}
