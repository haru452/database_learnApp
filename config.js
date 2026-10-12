// Supabase の接続情報。
// Supabase ダッシュボード → Project Settings → API (または API Keys) で確認できる。
//
// ・SUPABASE_URL      : "Project URL"
// ・SUPABASE_ANON_KEY : "anon public" キー (新しいプロジェクトでは "publishable key" と表示されることがある)
//
// anon キーは「ブラウザに公開される前提」の鍵なので、このファイルを GitHub に上げても問題ない。
// (データの保護は、schema.sql の RLS が担当している)
// ただし、"service_role" キー (secret) は、絶対にここへ書かない。
export const SUPABASE_URL = "https://YOUR-PROJECT-REF.supabase.co";
export const SUPABASE_ANON_KEY = "YOUR-ANON-KEY";
