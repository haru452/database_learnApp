# chat-sync.ps1 を Windows のタスクスケジューラに登録する (1 回だけ実行する)。
#   powershell -ExecutionPolicy Bypass -File install-task.ps1
# 動くとき:
#   ・ログオンしたとき (Google ドライブが起動するのを待つため 3 分あとに)
#   ・3 時間ごと
#   ・パソコンが切れていて時刻を逃したら、次につけたときにすぐ (StartWhenAvailable)
# 送っていない日の分は、動いたときにまとめて送る。消すとき: install-task.ps1 -Remove

param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$TaskName = 'ClaudeEnglishChatSync'

if ($Remove) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "消しました: $TaskName"
  exit 0
}

$script = Join-Path $PSScriptRoot 'chat-sync.ps1'
if (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'claude-chat-sync\config.json'))) {
  Write-Host '先に chat-sync.ps1 -Setup を実行してください。'
  exit 1
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

$atLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$atLogon.Delay = 'PT3M'
$every3h = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 3)

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
  -MultipleInstances IgnoreNew

# ログオンしているときだけ、自分のユーザーで動かす (Google ドライブはログオン中しか見えないため)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

$desc = 'Claude との英語の会話のミスを Google ドライブから読んで、英語学習の Web に送る'
try {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atLogon, $every3h) `
    -Settings $settings -Principal $principal -Description $desc -Force | Out-Null
  Write-Host "登録しました: $TaskName (ログオン時 + 3 時間ごと)"
} catch {
  # ログオン時のきっかけは、管理者でないと登録できないことがある。そのときは 3 時間ごとだけにする
  # (切れていた分は StartWhenAvailable で、つけたあとすぐに動く)
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($every3h) `
    -Settings $settings -Principal $principal -Description $desc -Force | Out-Null
  Write-Host "登録しました: $TaskName (3 時間ごと。ログオン時も足すなら、管理者の PowerShell でもう一度実行)"
}
Write-Host 'すぐ試すには: Start-ScheduledTask -TaskName ClaudeEnglishChatSync'
Write-Host "ログ: $env:LOCALAPPDATA\claude-chat-sync\log.txt"
