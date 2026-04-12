#Requires -Version 5.1
<#
.SYNOPSIS
    windows-memory-optimizer 共通ユーティリティ
.DESCRIPTION
    report.ps1 / cleanup.ps1 / setup.ps1 から dot-source で読み込む共通関数。
    . "$PSScriptRoot\..\lib\common.ps1"
#>

Set-StrictMode -Version Latest

# ---- メモリ情報 ----

function Get-SystemMemoryInfo {
    <#
    .SYNOPSIS  システム全体のメモリ情報を取得する
    .OUTPUTS   [PSCustomObject] TotalGB / UsedGB / FreeGB / TotalKB / UsedKB
    #>
    $os     = Get-CimInstance -ClassName Win32_OperatingSystem
    $totalKB = $os.TotalVisibleMemorySize
    $freeKB  = $os.FreePhysicalMemory
    $usedKB  = $totalKB - $freeKB
    [PSCustomObject]@{
        TotalGB = [math]::Round($totalKB / 1MB, 1)
        UsedGB  = [math]::Round($usedKB  / 1MB, 1)
        FreeGB  = [math]::Round($freeKB  / 1MB, 1)
        TotalKB = $totalKB
        UsedKB  = $usedKB
    }
}

function Get-MemoryBar {
    <#
    .SYNOPSIS  使用率をバーグラフ文字列で返す
    #>
    param(
        [double]$UsedGB,
        [double]$TotalGB,
        [int]$Width = 30
    )
    $ratio  = if ($TotalGB -gt 0) { $UsedGB / $TotalGB } else { 0 }
    $filled = [int]($ratio * $Width)
    $bar    = "[" + ("#" * $filled) + ("-" * ($Width - $filled)) + "]"
    "$bar $("{0:0.0}" -f ($ratio * 100))%"
}

# ---- ログ出力（cleanup.ps1 用） ----

function Write-LogLine {
    <#
    .SYNOPSIS  レベル付きログ行を Write-Host に出力し、指定されたログリストに追記する
    .PARAMETER Level  step / done / skip / fail
    .PARAMETER Log    ログ行を追記するリスト（省略可）
    #>
    param(
        [ValidateSet("step", "done", "skip", "fail")]
        [string]$Level,
        [string]$Message,
        [System.Collections.Generic.List[string]]$Log
    )
    $colorMap = @{
        step = "Cyan"
        done = "Green"
        skip = "Yellow"
        fail = "Red"
    }
    $prefixMap = @{
        step = "`n>> "
        done = "   OK: "
        skip = "   SKIP: "
        fail = "   FAIL: "
    }
    $line = "$($prefixMap[$Level])$Message"
    Write-Host $line -ForegroundColor $colorMap[$Level]

    if ($Log) { $Log.Add($line) }
}

# ---- プロセス・WSL・Docker 情報 ----

function Get-TopProcesses {
    <#
    .SYNOPSIS  メモリ使用量上位のプロセスを取得する
    #>
    param([int]$Top = 10)
    Get-Process |
        Where-Object { $_.WorkingSet64 -gt 0 } |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            [PSCustomObject]@{
                Name  = $_.ProcessName
                PID   = $_.Id
                MemMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
            }
        }
}

function Get-WslMemory {
    <#
    .SYNOPSIS  WSL2 の vmmem メモリ使用量と起動中インスタンス一覧を取得する
    #>
    $result = [PSCustomObject]@{ Running = $false; MemMB = 0; Instances = @() }
    try {
        $vmmem = Get-Process -Name "vmmem", "vmmemWSL" -ErrorAction SilentlyContinue
        if (-not $vmmem) { return $result }

        $result.Running = $true
        $result.MemMB   = [math]::Round(($vmmem | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)

        $result.Instances = wsl --list --verbose 2>$null |
            ForEach-Object { ($_ -replace '\x00', '').Trim() } |
            Select-Object -Skip 1 |
            Where-Object { $_ -match '\S' } |
            ForEach-Object {
                $parts = ($_ -replace '\*', '').Trim() -replace '\s+', ' ' -split ' '
                if ($parts.Count -ge 2) {
                    [PSCustomObject]@{ Name = $parts[0]; State = $parts[1] }
                }
            } | Where-Object { $null -ne $_ }
    } catch {
        # WSL not installed or error
    }
    return $result
}

function Get-DockerCommand {
    <#
    .SYNOPSIS  利用可能な docker コマンドを検出する (Windows側 → WSL2内)
    .OUTPUTS   [string] "docker" / "wsl docker" / $null
    #>

    # Windows 側の docker を確認
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        docker info 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return "docker" }
    }

    # WSL2 内の docker を確認 (wsl コマンドが無い環境ではスキップ)
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        $wslDocker = wsl which docker 2>$null
        if ($LASTEXITCODE -eq 0 -and $wslDocker) {
            wsl docker info 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return "wsl docker" }
        }
    }

    return $null
}

function Invoke-DockerCommand {
    <#
    .SYNOPSIS  Get-DockerCommand で検出した docker コマンドを安全に実行する
    .PARAMETER DockerCmd  Get-DockerCommand の戻り値 ("docker" / "wsl docker")
    .PARAMETER Arguments  docker サブコマンドと引数 (例: "container prune -f")
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DockerCmd,
        [Parameter(Mandatory)]
        [string]$Arguments
    )
    Invoke-Expression "$DockerCmd $Arguments 2>`$null"
}

function Get-DockerMemory {
    <#
    .SYNOPSIS  Docker コンテナ別メモリ使用量を取得する
    #>
    $result = [PSCustomObject]@{ Running = $false; TotalMB = 0; Containers = @() }
    try {
        $dockerCmd = Get-DockerCommand
        if (-not $dockerCmd) { return $result }
        $result.Running = $true

        $containerLines = Invoke-DockerCommand $dockerCmd "ps --format '{{.ID}}`t{{.Names}}`t{{.Image}}'"
        if (-not $containerLines) { return $result }

        $statsMap = @{}
        Invoke-DockerCommand $dockerCmd "stats --no-stream --format '{{.ID}}`t{{.MemUsage}}'" | ForEach-Object {
            $parts = $_ -split "`t"
            if ($parts.Count -ge 2) { $statsMap[$parts[0].Substring(0, 12)] = $parts[1] }
        }

        $containers = foreach ($line in $containerLines) {
            $parts    = $line -split "`t"
            $id       = $parts[0].Substring(0, 12)
            $memUsage = if ($statsMap.ContainsKey($id)) { $statsMap[$id] } else { "N/A" }
            $memMB    = 0
            if ($memUsage -match '^([\d.]+)([MmGg])iB') {
                $val   = [double]$Matches[1]
                $memMB = if ($Matches[2].ToUpper() -eq 'G') { $val * 1024 } else { $val }
            }
            [PSCustomObject]@{
                ID    = $id
                Name  = $parts[1]
                Image = $parts[2]
                MemMB = [math]::Round($memMB, 1)
                Usage = $memUsage
            }
        }

        $result.Containers = @($containers)
        $result.TotalMB    = [math]::Round(($containers | Measure-Object MemMB -Sum).Sum, 1)
    } catch {
        # Docker not running
    }
    return $result
}

# ---- Slack 通知 ----

function Send-SlackNotification {
    <#
    .SYNOPSIS  Slack に attachment 形式でメッセージを送る
    .DESCRIPTION
        notify.ps1 のロジックを関数化。
        トークン・チャンネルは環境変数 SLACK_BOT_TOKEN / SLACK_CHANNEL にフォールバックする。
    #>
    param(
        [string]$Token,
        [string]$Channel,
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$Title = "Windows Memory Optimizer",
        [string]$Color = "good"
    )

    $resolvedToken   = if ($Token)   { $Token }   else { $env:SLACK_BOT_TOKEN }
    $resolvedChannel = if ($Channel) { $Channel } else { $env:SLACK_CHANNEL   }

    if (-not $resolvedToken)   { Write-Warning "SLACK_BOT_TOKEN が未設定のため通知をスキップします"; return }
    if (-not $resolvedChannel) { Write-Warning "SLACK_CHANNEL が未設定のため通知をスキップします"; return }

    $colorMap = @{ good = "#36a64f"; warning = "#ffcc00"; danger = "#ff0000" }
    $hexColor = if ($colorMap.ContainsKey($Color)) { $colorMap[$Color] } else { $Color }

    # PS 5.1 互換の Unix タイムスタンプ
    $unixTs = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $payload = @{
        channel     = $resolvedChannel
        text        = $Title
        attachments = @(
            @{
                title     = $Title
                text      = $Message
                color     = $hexColor
                footer    = "windows-memory-optimizer"
                ts        = $unixTs
                mrkdwn_in = @("text")
            }
        )
    } | ConvertTo-Json -Depth 5

    $headers = @{
        Authorization  = "Bearer $resolvedToken"
        "Content-Type" = "application/json; charset=utf-8"
    }

    try {
        $response = Invoke-RestMethod `
            -Uri     "https://slack.com/api/chat.postMessage" `
            -Method  Post `
            -Headers $headers `
            -Body    ([System.Text.Encoding]::UTF8.GetBytes($payload))

        if ($response.ok) {
            Write-Host "Slack への通知が完了しました (channel: $resolvedChannel)" -ForegroundColor Green
        } else {
            Write-Error "Slack API エラー: $($response.error)"
        }
    } catch {
        Write-Error "Slack への送信に失敗しました: $_"
    }
}
