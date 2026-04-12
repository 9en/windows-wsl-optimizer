#Requires -Version 5.1
<#
.SYNOPSIS
    ワンコマンドでWindowsメモリをクリーンアップする
.DESCRIPTION
    WSL2メモリ解放・Dockerキャッシュ削除・Windowsファイルキャッシュクリア・
    不要プロセス確認をまとめて実行します。
.EXAMPLE
    .\cleanup.ps1
    .\cleanup.ps1 -DryRun
    .\cleanup.ps1 -SkipDocker -SkipWsl
    .\cleanup.ps1 -SkipPruneImages       # タグ付きイメージの削除をスキップ
    .\cleanup.ps1 -SkipPruneBuildCache    # ビルドキャッシュの全削除をスキップ
    .\cleanup.ps1 -PruneVolumes           # Dockerボリュームも削除（データ消失リスクあり）
    .\cleanup.ps1 -Report -Notify         # クリーンアップ後にレポート表示+通知
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipDocker,
    [switch]$SkipWsl,
    [switch]$SkipWindowsCache,
    # 未使用Dockerイメージの全削除をスキップする（デフォルトでタグ付き含め全削除）
    [switch]$SkipPruneImages,
    # Dockerビルドキャッシュの全削除をスキップする（デフォルトで全削除）
    [switch]$SkipPruneBuildCache,
    # 未使用Dockerボリュームも削除する（停止中コンテナのデータが消えるため要注意）
    [switch]$PruneVolumes,
    [switch]$Notify,
    # クリーンアップ後にメモリレポートを表示する
    [switch]$Report
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

. "$PSScriptRoot\lib\common.ps1"

# ログバッファ（Write-LogLine の -Log パラメータに渡す）
$_log = [System.Collections.Generic.List[string]]::new()

$timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$memBefore  = (Get-SystemMemoryInfo).UsedKB   # クリーンアップ前の使用量

Write-Host ("=" * 60) -ForegroundColor White
Write-Host "  Windows Memory Optimizer - Cleanup" -ForegroundColor White
Write-Host "  $timestamp" -ForegroundColor White
if ($DryRun) { Write-Host "  [DRY RUN MODE - no changes will be made]" -ForegroundColor Yellow }
Write-Host ("=" * 60) -ForegroundColor White

# ---- 1. WSL2 ページキャッシュ解放 ----
if (-not $SkipWsl) {
    Write-LogLine -Log $_log step "WSL2 メモリ解放"
    try {
        $vmmem = Get-Process -Name "vmmem", "vmmemWSL" -ErrorAction SilentlyContinue
        if ($vmmem) {
            if ($DryRun) {
                Write-LogLine -Log $_log skip "WSL2 ページキャッシュ解放 (dry run)"
            } else {
                $distros = wsl --list --quiet 2>$null |
                    ForEach-Object { ($_ -replace '\x00', '').Trim() } |
                    Where-Object { $_ -match '^\S+$' }
                foreach ($distro in $distros) {
                    wsl -d $distro --exec sh -c "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1" 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        Write-LogLine -Log $_log done "[$distro] ページキャッシュを解放しました"
                    } else {
                        Write-LogLine -Log $_log fail "[$distro] ページキャッシュ解放に失敗しました"
                    }
                }
            }
        } else {
            Write-LogLine -Log $_log skip "WSL2 は起動していません"
        }
    } catch {
        Write-LogLine -Log $_log fail "WSL2操作中にエラー: $_"
    }
}

# ---- 2. Docker キャッシュクリア ----
if (-not $SkipDocker) {
    Write-LogLine -Log $_log step "Docker キャッシュクリア"
    try {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-LogLine -Log $_log skip "Docker がインストールされていません"
        } elseif (-not (docker info 2>$null) -or $LASTEXITCODE -ne 0) {
            Write-LogLine -Log $_log skip "Docker は起動していません"
        } else {
            # ディスク使用量を表示
            $dfOutput = docker system df 2>$null
            if ($dfOutput) {
                Write-Host "   [Docker ディスク使用量]" -ForegroundColor White
                $dfOutput | ForEach-Object { Write-Host "   $_" }
                $_log.Add("[Docker ディスク使用量]")
                $dfOutput | ForEach-Object { $_log.Add("  $_") }
            }

            if ($DryRun) {
                Write-LogLine -Log $_log skip "Docker prune (dry run)"
            } else {
                docker container prune -f 2>$null | Out-Null; Write-LogLine -Log $_log done "停止コンテナを削除しました"

                if ($SkipPruneBuildCache) {
                    docker builder prune -f 2>$null | Out-Null
                    Write-LogLine -Log $_log done "未使用ビルドキャッシュを削除しました（最近使用分は保持）"
                } else {
                    docker builder prune -a -f 2>$null | Out-Null
                    Write-LogLine -Log $_log done "ビルドキャッシュを全て削除しました"
                }

                docker network prune -f 2>$null | Out-Null; Write-LogLine -Log $_log done "未使用ネットワークを削除しました"

                if ($SkipPruneImages) {
                    docker image prune -f 2>$null | Out-Null
                    Write-LogLine -Log $_log done "未使用イメージ（タグなし）を削除しました"
                } else {
                    docker image prune -a -f 2>$null | Out-Null
                    Write-LogLine -Log $_log done "未使用イメージを全て削除しました"
                }

                if ($PruneVolumes) {
                    Write-Host "   [警告] 未使用ボリュームを削除します。停止中コンテナのデータが失われる可能性があります。" -ForegroundColor Red
                    docker volume prune -f 2>$null | Out-Null
                    Write-LogLine -Log $_log done "未使用ボリュームを削除しました"
                } else {
                    Write-LogLine -Log $_log skip "Dockerボリューム削除はスキップ（有効化: -PruneVolumes）"
                }
            }
        }
    } catch {
        Write-LogLine -Log $_log fail "Docker操作中にエラー: $_"
    }
}

# ---- 3. Windows 一時ファイル削除 ----
if (-not $SkipWindowsCache) {
    Write-LogLine -Log $_log step "Windows 一時ファイル・キャッシュクリア"

    $tempPaths = @(
        $env:TEMP,
        $env:TMP,
        "$env:LOCALAPPDATA\Temp",
        "$env:WINDIR\Temp"
    ) | Select-Object -Unique | Where-Object { Test-Path $_ }

    foreach ($path in $tempPaths) {
        if ($DryRun) {
            $count = (Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-LogLine -Log $_log skip "$path ($count 件対象, dry run)"
        } else {
            try {
                $removed = 0
                Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    try { Remove-Item -Path $_.FullName -Force -Recurse -ErrorAction SilentlyContinue; $removed++ } catch { }
                }
                Write-LogLine -Log $_log done "$path ($removed 件削除)"
            } catch {
                Write-LogLine -Log $_log fail "$path : $_"
            }
        }
    }

    if ($DryRun) {
        Write-LogLine -Log $_log skip "DNS キャッシュクリア (dry run)"
    } else {
        try {
            ipconfig /flushdns | Out-Null
            Write-LogLine -Log $_log done "DNS キャッシュをクリアしました"
        } catch {
            Write-LogLine -Log $_log fail "DNS キャッシュクリア失敗: $_"
        }
    }
}

# ---- 4. 高メモリプロセスの表示（停止はしない）----
Write-LogLine -Log $_log step "高メモリプロセスの確認 (500MB超、参考表示のみ)"
$highMemProcs = Get-TopProcesses -Top 5 | Where-Object { $_.MemMB -gt 500 }

if ($highMemProcs) {
    foreach ($p in $highMemProcs) {
        Write-Host ("   {0,-30} {1,6} MB" -f $p.Name, [math]::Round($p.MemMB, 0)) -ForegroundColor White
    }
} else {
    Write-LogLine -Log $_log done "500MB超のプロセスはありません"
}

# ---- サマリー ----
$sysAfter = Get-SystemMemoryInfo
$freed    = [math]::Round(($memBefore - $sysAfter.UsedKB) / 1KB, 1)

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor White
Write-Host "  クリーンアップ完了" -ForegroundColor Green
Write-Host "  実行前 : $([math]::Round($memBefore / 1MB, 1)) GB 使用中" -ForegroundColor White
Write-Host "  実行後 : $($sysAfter.UsedGB) GB 使用中" -ForegroundColor White
if ($freed -gt 0) {
    Write-Host "  解放量 : $freed MB" -ForegroundColor Green
} else {
    Write-Host "  解放量 : $freed MB (OS再利用待ち)" -ForegroundColor Yellow
}
Write-Host ("=" * 60) -ForegroundColor White

$_log.Add("")
$_log.Add("実行前: $([math]::Round($memBefore / 1MB, 1)) GB  →  実行後: $($sysAfter.UsedGB) GB  (解放: $freed MB)")

# ---- レポート出力 ----
if ($Report) {
    Write-Host ""
    & "$PSScriptRoot\report.ps1" -Notify:$Notify
} elseif ($Notify) {
    Send-SlackNotification -Message ("【Cleanup完了】`n" + ($_log -join "`n"))
}
