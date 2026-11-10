// Supabase の接続 (config.js が設定済みのときだけ読み込む)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "../../config.js";
import { createStreakApi } from "../streak-client.js";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
export const api = createStreakApi(supabase);
