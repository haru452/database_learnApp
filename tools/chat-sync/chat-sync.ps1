# Claude との英語の会話で直してもらったミスを、Web (Supabase) に送る。
#
# Claude は Google Drive の claude-english-mistakes フォルダに YYYY-MM-DD_chat.json を置く。
# このスクリプトは、パソコンの Google ドライブ (Google Drive for desktop) のそのフォルダを読み、
# まだ送っていない分を save_chat_day (supabase/chat.sql) で送る。送った日は連続記録にも数える。
#
# 使い方:
#   最初の 1 回:  powershell -ExecutionPolicy Bypass -File chat-sync.ps1 -Setup
#   送る:         powershell -ExecutionPolicy Bypass -File chat-sync.ps1
#   試すだけ:     powershell -ExecutionPolicy Bypass -File chat-sync.ps1 -DryRun
# 自動で動かすには install-task.ps1 を 1 回実行する。
#
# 設定・送った記録・ログは %LOCALAPPDATA%\claude-chat-sync に置く。
# パスワードは Windows の DPAPI で暗号化して保存する (このパソコンの、この Windows ユーザーだけが読める)。

param(
  [switch]$Setup,
  [switch]$DryRun,
  [string]$Folder
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$DataDir    = Join-Path $env:LOCALAPPDATA 'claude-chat-sync'
$ConfigPath = Join-Path $DataDir 'config.json'
$SentPath   = Join-Path $DataDir 'sent.json'
$LogPath    = Join-Path $DataDir 'log.txt'
$DriveFolderName = 'claude-english-mistakes'
$Batch = 20   # save_chat_day は 1 回に 20 件まで受け取る

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

function Write-Log([string]$msg) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Write-Host $line
  Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Read-Json([string]$path) {
  return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-Json([string]$path, $obj) {
  $json = ConvertTo-Json -InputObject $obj -Depth 6
  [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

# リポジトリの config.js から Supabase の URL と anon キーを読む (Web と同じ値を使う)
function Get-SupabaseConfig {
  $configJs = Join-Path $PSScriptRoot '..\..\config.js'
  $text = Get-Content -Path $configJs -Raw -Encoding UTF8
  $url = [regex]::Match($text, 'SUPABASE_URL\s*=\s*"([^"]+)"').Groups[1].Value
  $key = [regex]::Match($text, 'SUPABASE_ANON_KEY\s*=\s*"([^"]+)"').Groups[1].Value
  if (-not $url -or -not $key) { throw "config.js から SUPABASE_URL / SUPABASE_ANON_KEY を読めませんでした: $configJs" }
  return @{ Url = $url.TrimEnd('/'); Key = $key }
}

# Google ドライブの中の claude-english-mistakes フォルダを探す (G:\マイドライブ など)
function Find-DriveFolder {
  $names = @('マイドライブ', 'My Drive')
  foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
    foreach ($n in $names) {
      $p = Join-Path $d.Root (Join-Path $n $DriveFolderName)
      if (Test-Path -LiteralPath $p) { return $p }
    }
  }
  return $null
}

function Invoke-Supabase([string]$method, [string]$url, $body, [string]$token) {
  $headers = @{ apikey = $script:Sb.Key }
  if ($token) { $headers['Authorization'] = "Bearer $token" }
  $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Depth 6 -Compress))
  return Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $bytes `
    -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
}

function Get-AccessToken($config) {
  $secure = ConvertTo-SecureString $config.passwordEnc
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  $res = Invoke-Supabase 'Post' "$($script:Sb.Url)/auth/v1/token?grant_type=password" `
    @{ email = $config.email; password = $plain } $null
  return $res.access_token
}

# ---------- 設定 ----------
$script:Sb = Get-SupabaseConfig

if ($Setup) {
  Write-Host '--- Claude の添削を Web に送る設定 ---'
  $found = Find-DriveFolder
  if ($Folder) { $found = $Folder }
  if ($found) {
    Write-Host "Google ドライブのフォルダ: $found"
    $ans = Read-Host 'これでよければ Enter、違うなら正しい場所を入力'
    if ($ans) { $found = $ans }
  } else {
    $found = Read-Host "Google ドライブの $DriveFolderName フォルダの場所を入力 (例: G:\マイドライブ\$DriveFolderName)"
  }
  if (-not (Test-Path -LiteralPath $found)) { throw "フォルダが見つかりません: $found" }

  $email = Read-Host 'Web にログインするメールアドレス'
  $pass  = Read-Host 'パスワード' -AsSecureString
  $config = [ordered]@{ folder = $found; email = $email; passwordEnc = (ConvertFrom-SecureString $pass) }

  # ログインできるか確かめてから保存する
  $token = Get-AccessToken ([pscustomobject]$config)
  if (-not $token) { throw 'ログインできませんでした。' }
  Write-Json $ConfigPath $config
  Write-Host "保存しました: $ConfigPath"
  Write-Host 'ログインできました。続けて送るには、-Setup を付けずに実行してください。'
  exit 0
}

if (-not (Test-Path $ConfigPath)) {
  Write-Log "設定がありません。先に -Setup を付けて実行してください。"
  exit 1
}
$config = Read-Json $ConfigPath
$folderPath = if ($Folder) { $Folder } else { $config.folder }
if (-not (Test-Path -LiteralPath $folderPath)) {
  # Google ドライブがまだ起動していないとき。次の実行でまとめて送る
  Write-Log "フォルダがまだ見えません (Google ドライブが起動していない?): $folderPath"
  exit 0
}

# 送った記録: { "2026-11-19_chat.json": 11 }  (そのファイルの先頭から何件送ったか)
$sent = @{}
if (Test-Path $SentPath) {
  (Read-Json $SentPath).PSObject.Properties | ForEach-Object { $sent[$_.Name] = [int]$_.Value }
}

# ---------- 送る ----------
$files = Get-ChildItem -LiteralPath $folderPath -Filter '*_chat.json' -File |
  Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_chat\.json$' } | Sort-Object Name

$token = $null
$total = 0
foreach ($f in $files) {
  try {
    $data = Read-Json $f.FullName
  } catch {
    Write-Log "読めないファイルを飛ばします: $($f.Name) ($($_.Exception.Message))"
    continue
  }
  $date = if ($data.date -match '^\d{4}-\d{2}-\d{2}$') { $data.date } else { $f.Name.Substring(0, 10) }
  $tz = if ($data.timezone) { [string]$data.timezone } else { 'Asia/Tokyo' }
  $mistakes = @()
  if ($null -ne $data.mistakes) { $mistakes = @($data.mistakes) }

  $done = if ($sent.ContainsKey($f.Name)) { $sent[$f.Name] } else { -1 }   # -1 = まだ一度も送っていない
  if ($done -ge $mistakes.Count -and $done -ge 0) { continue }             # 新しい分が無い

  # 送る範囲 (同じ日のファイルに後から足された分だけ送る)。ミスが 0 件の日も 1 回送って連続記録に数える
  $start = [Math]::Max($done, 0)
  $offsets = @()
  if ($mistakes.Count -eq 0) { $offsets = @(0) } else { for ($i = $start; $i -lt $mistakes.Count; $i += $Batch) { $offsets += $i } }

  foreach ($off in $offsets) {
    $chunk = @()
    if ($mistakes.Count -gt 0) { $chunk = @($mistakes[$off..([Math]::Min($off + $Batch, $mistakes.Count) - 1)]) }
    # note (日本語の説明) は Web の表に列が無いので、wrong / fixed / type だけ送る
    $payload = @($chunk | ForEach-Object { @{ type = [string]$_.type; wrong = [string]$_.wrong; fixed = [string]$_.fixed } })
    $key = "$($f.Name)#$off"

    if ($DryRun) {
      Write-Log "[試すだけ] $key  日付 $date  ミス $($payload.Count) 件"
      continue
    }
    if (-not $token) {
      try { $token = Get-AccessToken $config } catch {
        Write-Log "ログインできませんでした (ネットにつながっていない? 次の実行でもう一度): $($_.Exception.Message)"
        exit 0
      }
    }
    try {
      $res = Invoke-Supabase 'Post' "$($script:Sb.Url)/rest/v1/rpc/save_chat_day" @{
        p_file_key = $key; p_date = $date; p_mistakes = $payload; p_timezone = $tz
      } $token
      $row = @($res)[0]
      if ($row.already_sent) {
        Write-Log "送信済みでした: $key"
      } else {
        Write-Log "送りました: $key  ミス $($row.saved) 件  連続記録 $($row.streak) 日"
        $total += [int]$row.saved
      }
    } catch {
      $msg = $_.Exception.Message
      if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
      if ($msg -match 'invalid date') {
        Write-Log "日付が古すぎる (90 日より前) か未来なので飛ばします: $key"
      } else {
        Write-Log "送れませんでした (次の実行でもう一度): $key  $msg"
        break
      }
    }
    $sent[$f.Name] = [Math]::Max([Math]::Min($off + $Batch, $mistakes.Count), 0)
    Write-Json $SentPath $sent
  }
}

if (-not $DryRun) { Write-Log "おわり (新しく送ったミス: $total 件)" }

# ログは新しい 500 行だけ残す
$lines = @(Get-Content -Path $LogPath -Encoding UTF8)
if ($lines.Count -gt 500) { Set-Content -Path $LogPath -Value $lines[-500..-1] -Encoding UTF8 }
