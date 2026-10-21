// streak-client.js
// Supabase の認証 (メール/パスワード) と、連続学習記録 (ストリーク) を扱う小さなモジュール。
// どのフレームワークでも使えるよう、Supabase のクライアントは「外から渡す」形にしている。
//
//   import { createClient } from "@supabase/supabase-js";
//   import { createStreakApi } from "./streak-client.js";
//
//   const supabase = createClient(URL, ANON_KEY);
//   const api = createStreakApi(supabase);
//
//   await api.signUp(email, password);
//   await api.signIn(email, password);
//   const { streak } = await api.getStreak();        // 画面に表示する連続日数
//   const result = await api.completeStudy();         // 「学習完了」ボタン

export function createStreakApi(supabase) {
  // 「今日」の判定に使うタイムゾーン (利用者の端末の設定。例: "Asia/Tokyo")。
  // 日付の判定そのものは、DB 側 (サーバーの時刻) で行う
  function timeZone() {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
    } catch {
      return "UTC";
    }
  }

  async function callRpc(name) {
    const { data, error } = await supabase.rpc(name, { p_timezone: timeZone() });
    if (error) throw error;
    return Array.isArray(data) ? data[0] : data;
  }

  return {
    // ---------------- 認証 ----------------

    /**
     * 新規登録。メール確認が ON のプロジェクトでは、確認メールのリンクを開くまでログインできない。
     * @returns {{ needsEmailConfirmation: boolean }}
     */
    async signUp(email, password) {
      const { data, error } = await supabase.auth.signUp({
        email,
        password,
        options: { emailRedirectTo: window.location.origin },
      });
      if (error) throw error;

      // 登録済みのメールアドレスで、メール確認が ON の場合、Supabase はエラーを返さず、
      // identities が空のユーザーを返す (登録の有無を外部から調べられないようにするため)
      if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
        const err = new Error("User already registered");
        err.code = "user_already_exists";
        throw err;
      }
      return { needsEmailConfirmation: !data.session };
    },

    async signIn(email, password) {
      const { data, error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) throw error;
      return data.user;
    },

    /** 新しいパスワードに変える (パスワード再設定メールのリンクから開いたとき) */
    async updatePassword(newPassword) {
      const { error } = await supabase.auth.updateUser({ password: newPassword });
      if (error) throw error;
    },

    /** パスワード再設定メールのリンクから開かれたときに callback() を呼ぶ */
    onPasswordRecovery(callback) {
      const { data } = supabase.auth.onAuthStateChange((event) => {
        if (event === "PASSWORD_RECOVERY") setTimeout(callback, 0);
      });
      return () => data.subscription.unsubscribe();
    },

    /** パスワード再設定のメールを送る (メールのリンクは Supabase の Site URL に戻ってくる) */
    async sendPasswordReset(email) {
      const { error } = await supabase.auth.resetPasswordForEmail(email);
      if (error) throw error;
    },

    async signOut() {
      const { error } = await supabase.auth.signOut();
      if (error) throw error;
    },

    /** 現在ログイン中のユーザー (未ログインなら null) */
    async getUser() {
      const { data, error } = await supabase.auth.getSession();
      if (error) throw error;
      return data.session ? data.session.user : null;
    },

    /**
     * ログイン状態の変化を監視する。callback(user | null)。解除用の関数を返す。
     * 同じユーザーのままトークンが更新されただけのときは、呼ばない。
     */
    onAuthChange(callback) {
      let lastId;   // undefined = まだ一度も通知していない
      const { data } = supabase.auth.onAuthStateChange((_event, session) => {
        const user = session ? session.user : null;
        const id = user ? user.id : null;
        if (id === lastId) return;
        lastId = id;
        // コールバックの中で、すぐに Supabase を呼ぶと止まることがあるため、次のタイミングに回す
        setTimeout(() => callback(user), 0);
      });
      return () => data.subscription.unsubscribe();
    },

    // ---------------- ストリーク ----------------

    /**
     * いま有効な連続日数。最後の学習が一昨日以前なら、途切れているので 0。
     * best は、これまでの最長記録 (アプリと共通)。
     * @returns {{ streak: number, lastDate: string|null, studiedToday: boolean, best: number }}
     */
    async getStreak() {
      const row = await callRpc("get_my_streak");
      return {
        streak: row ? row.streak : 0,
        lastDate: row ? row.last_date : null,
        studiedToday: row ? row.studied_today : false,
        best: row ? Math.max(row.best_streak || 0, row.streak) : 0,
      };
    },

    /**
     * 「学習完了」。昨日まで続いていれば +1、今日すでに完了していればそのまま、空いていれば 1。
     * @returns {{ streak: number, lastDate: string, alreadyDone: boolean, best: number }}
     */
    async completeStudy() {
      const row = await callRpc("complete_study");
      return {
        streak: row.streak,
        lastDate: row.last_date,
        alreadyDone: row.already_done,
        best: Math.max(row.best_streak || 0, row.streak),
      };
    },

    // ---------------- やった日カレンダー ----------------

    /**
     * 期間内の「やった日」(日付の古い順)。日記をやった日 / 要約練習をやった日。
     * @param {string} from "yyyy-mm-dd"   @param {string} to "yyyy-mm-dd" (約1年分まで)
     * @returns {Array<{ date: string, diary: boolean, summary: boolean, topic: boolean }>}
     */
    async getActivityDays(from, to) {
      const { data, error } = await supabase.rpc("get_my_activity_days", { p_from: from, p_to: to });
      if (error) throw error;
      return (data || []).map((r) => ({ date: r.day, diary: !!r.diary, summary: !!r.summary, topic: !!r.topic }));
    },

    // ---------------- 日記 (アプリで保存された、直近7日分) ----------------

    /**
     * 保存されている日記 (新しい順)。古いもの (7日より前) は、サーバーが自動で消す。
     * @returns {Array<{ id: number, date: string, original: string, corrected: string,
     *                   explanation: string, engine: string, createdAt: string }>}
     */
    async getDiary() {
      const { data, error } = await supabase.rpc("get_my_diary", { p_timezone: timeZone() });
      if (error) throw error;
      return (data || []).map((r) => ({
        id: r.id,
        date: r.entry_date,
        original: r.original_text,
        corrected: r.corrected_text,
        explanation: r.explanation || "",
        engine: r.engine || "",
        createdAt: r.created_at,
      }));
    },

    // ---------------- 要約練習 (Versant 対策) の採点結果 ----------------

    /**
     * 採点結果 (新しい順)。点数の推移を見るため、古いものも残っている (新しい 1000 件まで)。
     * @returns {Array<{ id: number, date: string, createdAt: string, videoId: string, videoTitle: string,
     *                   timeLimit: number, score: number, contentScore: number|null,
     *                   organizationScore: number|null, languageScore: number|null,
     *                   transcript: string, referenceSummary: string,
     *                   goodPoints: string, missedPoints: string, languageFeedback: string,
     *                   improvedSummary: string }>}
     */
    async getSummaryResults(limit = 20) {   // データベースには新しい 20 件だけ残っている
      const { data, error } = await supabase.rpc("get_my_summary_results", {
        p_timezone: timeZone(),
        p_limit: limit,
      });
      if (error) throw error;
      return (data || []).map((r) => ({
        id: r.id,
        date: r.entry_date,
        createdAt: r.created_at,
        videoId: r.video_id || "",
        videoTitle: r.video_title || "",
        timeLimit: r.time_limit_seconds,
        score: r.score,
        // 項目ごとの点数 (内容 50 + 構成 25 + 文法・語彙 25)。項目別の採点を入れる前の結果は null
        contentScore: r.content_score,
        organizationScore: r.organization_score,
        languageScore: r.language_score,
        transcript: r.transcript || "",
        referenceSummary: r.reference_summary || "",
        goodPoints: r.good_points || "",
        missedPoints: r.missed_points || "",
        languageFeedback: r.language_feedback || "",
        improvedSummary: r.improved_summary || "",
      }));
    },

    // ---------------- お題スピーキング (アプリで保存された、新しい 20 件) ----------------

    /** @returns 新しい順。点数は 内容 40 + 構成 30 + 文法・語彙 30 */
    async getTopicResults(limit = 20) {
      const { data, error } = await supabase.rpc("get_my_topic_results", { p_limit: limit });
      if (error) throw error;
      return (data || []).map((r) => ({
        id: r.id,
        date: r.entry_date,
        createdAt: r.created_at,
        kind: r.kind,
        topic: r.topic || "",
        timeLimit: r.time_limit_seconds,
        score: r.score,
        contentScore: r.content_score,
        organizationScore: r.organization_score,
        languageScore: r.language_score,
        transcript: r.transcript || "",
        corrected: r.corrected || "",
        natural: r.natural_version || "",
        goodPoints: r.good_points || "",
        fixPoints: r.fix_points || "",
        phrases: r.phrases || "",
        readAloudAccuracy: r.read_aloud_accuracy,
      }));
    },

    // ---------------- よくあるミス ----------------

    /**
     * 直近 days 日のミスの種類ごとの回数 (多い順)。previousCount はその前の同じ日数の回数 (90 日のときは前のデータが無いので null)。
     * @returns {Array<{ type: string, count: number, previousCount: number|null,
     *                   examples: Array<{ wrong: string, fixed: string, source: string, date: string }> }>}
     */
    async getMistakeStats(days) {
      const { data, error } = await supabase.rpc("get_my_mistake_stats", { p_days: days });
      if (error) throw error;
      return (data || []).map((r) => ({
        type: r.type,
        count: r.count,
        previousCount: r.previous_count,
        examples: Array.isArray(r.examples) ? r.examples : [],
      }));
    },
  };
}

/** Supabase のエラーを、画面に出せる日本語のメッセージにする */
export function friendlyError(error) {
  const code = error && error.code;
  const message = (error && error.message) || String(error);

  const byCode = {
    invalid_credentials: "メールアドレスまたはパスワードが違います。",
    email_not_confirmed: "メールアドレスの確認がまだです。届いた確認メールのリンクを開いてください。",
    user_already_exists: "このメールアドレスは、すでに登録されています。ログインしてください。",
    weak_password: "パスワードが弱すぎます。8文字以上で、推測されにくいものにしてください。",
    over_email_send_rate_limit: "メールの送信回数の上限に達しました。しばらく待ってから、もう一度お試しください。",
    over_request_rate_limit: "操作が多すぎます。しばらく待ってから、もう一度お試しください。",
    signup_disabled: "現在、新規登録は受け付けていません。",
    validation_failed: "入力内容を確認してください。",
    same_password: "今と同じパスワードです。別のパスワードにしてください。",
    otp_expired: "リンクの有効期限が切れています。アプリの「Forgot password?」から、もう一度メールを送ってください。",
  };
  if (code && byCode[code]) return byCode[code];

  // コードが無い古い形式のエラー向けに、文面でも判定する
  if (/invalid login credentials/i.test(message)) return byCode.invalid_credentials;
  if (/email not confirmed/i.test(message)) return byCode.email_not_confirmed;
  if (/already registered/i.test(message)) return byCode.user_already_exists;
  if (/at least \d+ characters/i.test(message)) return "パスワードが短すぎます。";
  if (/get_my_summary_results/i.test(message)) return "要約練習の機能が、データベースにまだ追加されていません (supabase/summary.sql を実行してください)。";
  if (/not authenticated/i.test(message)) return "ログインの有効期限が切れました。もう一度ログインしてください。";
  if (/failed to fetch|networkerror|load failed/i.test(message)) return "通信に失敗しました。ネットワークを確認してください。";

  return "エラーが発生しました: " + message;
}
