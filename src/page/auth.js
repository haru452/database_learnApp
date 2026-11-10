import { $, fe, say, show, tr } from "./core.js";
import { api } from "./supabase.js";
import { loadStreak } from "./streak.js";

// パスワード再設定メールのリンクから開かれたか (URL の #...type=recovery、または PASSWORD_RECOVERY の通知)
export let recovering = /type=recovery/.test(location.hash);
api.onPasswordRecovery(() => {
  recovering = true;
  show("reset");
});

// ---------- ログイン / 新規登録 ----------
export let mode = "signin";
export function setModeLabels() {
  const signup = mode === "signup";
  $("auth-title").textContent = signup ? tr("アカウント作成", "Create account") : tr("ログイン", "Log in");
  $("auth-submit").textContent = signup ? tr("登録する", "Sign up") : tr("ログイン", "Log in");
  $("auth-toggle").textContent = signup ? tr("ログインに戻る", "Back to log in") : tr("アカウントを作成する", "Create an account");
}
export function setMode(next) {
  mode = next;
  const signup = mode === "signup";
  setModeLabels();
  $("password").autocomplete = signup ? "new-password" : "current-password";
  $("auth-forgot").hidden = signup;
  say($("auth-msg"), "");
}
setModeLabels();
$("auth-toggle").addEventListener("click", () => setMode(mode === "signin" ? "signup" : "signin"));

// パスワードを忘れた場合: 入力されたメールアドレスに、再設定用のリンクを送る
$("auth-forgot").addEventListener("click", async () => {
  const email = $("email").value.trim();
  if (!email || !email.includes("@")) {
    say($("auth-msg"), tr("上の欄にメールアドレスを入力してから、もう一度「パスワードを忘れた場合」を押してください。",
      "Enter your email above, then press \u201cForgot password?\u201d again."), "error");
    $("email").focus();
    return;
  }
  $("auth-forgot").disabled = true;
  say($("auth-msg"), tr("送信中...", "Sending..."));
  try {
    await api.sendPasswordReset(email);
    say($("auth-msg"),
      tr("登録されているメールアドレスなら、パスワード再設定のメールを送りました。メールのリンクを開いて、新しいパスワードを設定してください。",
        "If this email is registered, we sent a password reset email. Open the link in it to set a new password."),
      "ok");
  } catch (err) {
    say($("auth-msg"), fe(err), "error");
  } finally {
    $("auth-forgot").disabled = false;
  }
});

$("auth-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = $("email").value.trim();
  const password = $("password").value;
  if (!email || password.length < 8) {
    say($("auth-msg"), tr("メールアドレスと、8文字以上のパスワードを入力してください。", "Enter your email and a password of at least 8 characters."), "error");
    return;
  }

  $("auth-submit").disabled = true;
  say($("auth-msg"), tr("処理中...", "Working..."));
  try {
    if (mode === "signup") {
      const { needsEmailConfirmation } = await api.signUp(email, password);
      if (needsEmailConfirmation) {
        setMode("signin");   // setMode はメッセージを消すので、先に呼ぶ
        say($("auth-msg"), tr("確認メールを送信しました。メール内のリンクを開いてから、ログインしてください。",
          "We sent a confirmation email. Open the link in it, then log in."), "ok");
      }
      // 確認が不要な設定なら、そのままログイン状態になり、onAuthChange で画面が切り替わる
    } else {
      await api.signIn(email, password);
    }
    $("password").value = "";
  } catch (err) {
    say($("auth-msg"), fe(err), "error");
  } finally {
    $("auth-submit").disabled = false;
  }
});

// ---------- パスワード再設定 ----------
$("reset-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const pw = $("new-password").value;
  if (pw.length < 8) {
    say($("reset-msg"), tr("8文字以上のパスワードを入力してください。", "Enter a password of at least 8 characters."), "error");
    return;
  }
  if (pw !== $("new-password2").value) {
    say($("reset-msg"), tr("2つの入力が一致しません。", "The two passwords don't match."), "error");
    return;
  }
  $("reset-submit").disabled = true;
  say($("reset-msg"), tr("処理中...", "Working..."));
  try {
    await api.updatePassword(pw);
    recovering = false;
    history.replaceState(null, "", location.pathname + location.search);   // URL のトークンを消す
    $("new-password").value = "";
    $("new-password2").value = "";
    show("app");
    loadStreak();
    say($("app-msg"), tr("パスワードを変更しました。アプリでも新しいパスワードでログインできます。",
      "Your password was changed. You can also log in to the app with the new password."), "ok");
  } catch (err) {
    say($("reset-msg"), fe(err), "error");
  } finally {
    $("reset-submit").disabled = false;
  }
});
