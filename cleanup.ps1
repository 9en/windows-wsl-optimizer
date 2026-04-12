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
    # 未使用Dockerイメージを全て削除する（デフォルトはタグなしのみ削除）
    [switch]$PruneImages,
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
$diskBefore = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue).FreeSpace

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
        # Docker コマンドの検出: Windows側 → WSL2内 の順で探す
        $dockerCmd = Get-DockerCommand

        if (-not $dockerCmd) {
            Write-LogLine -Log $_log skip "Docker が見つかりません（Windows / WSL2 両方を確認済み）"
        } else {
            $dockerSource = if ($dockerCmd -eq "wsl docker") { "WSL2" } else { "Windows" }
            Write-LogLine -Log $_log done "Docker を検出しました ($dockerSource)"

            # ディスク使用量を表示
            $dfOutput = Invoke-DockerCommand $dockerCmd "system df"
            if ($dfOutput) {
                Write-Host "   [Docker ディスク使用量]" -ForegroundColor White
                $dfOutput | ForEach-Object { Write-Host "   $_" }
                $_log.Add("[Docker ディスク使用量]")
                $dfOutput | ForEach-Object { $_log.Add("  $_") }
            }

            if ($DryRun) {
                Write-LogLine -Log $_log skip "Docker prune (dry run)"
            } else {
                Invoke-DockerCommand $dockerCmd "container prune -f" | Out-Null
                Write-LogLine -Log $_log done "停止コンテナを削除しました"

                if ($SkipPruneBuildCache) {
                    Invoke-DockerCommand $dockerCmd "builder prune -f" | Out-Null
                    Write-LogLine -Log $_log done "未使用ビルドキャッシュを削除しました（最近使用分は保持）"
                } else {
                    Invoke-DockerCommand $dockerCmd "builder prune -a -f" | Out-Null
                    Write-LogLine -Log $_log done "ビルドキャッシュを全て削除しました"
                }

                Invoke-DockerCommand $dockerCmd "network prune -f" | Out-Null
                Write-LogLine -Log $_log done "未使用ネットワークを削除しました"

                if ($PruneImages) {
                    Invoke-DockerCommand $dockerCmd "image prune -a -f" | Out-Null
                    Write-LogLine -Log $_log done "未使用イメージを全て削除しました（タグ付き含む）"
                } else {
                    Invoke-DockerCommand $dockerCmd "image prune -f" | Out-Null
                    Write-LogLine -Log $_log done "未使用イメージ（タグなし）を削除しました"
                }

                if ($PruneVolumes) {
                    Write-Host "   [警告] 未使用ボリュームを削除します。停止中コンテナのデータが失われる可能性があります。" -ForegroundColor Red
                    Invoke-DockerCommand $dockerCmd "volume prune -f" | Out-Null
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

# ---- 3. WSL2 仮想ディスク (vhdx) 圧縮 ----
if (-not $SkipWsl) {
    Write-LogLine -Log $_log step "WSL2 仮想ディスク圧縮"
    try {
        # vhdx ファイルを検索（複数の既知パスを再帰的に走査）
        $vhdxSearchDirs = @(
            "$env:LOCALAPPDATA\Packages",
            "$env:LOCALAPPDATA\Docker"
        ) | Where-Object { Test-Path $_ }
        $vhdxPaths = @()
        foreach ($dir in $vhdxSearchDirs) {
            $found = Get-ChildItem -Path $dir -Filter "ext4.vhdx" -Recurse -ErrorAction SilentlyContinue
            if ($found) { $vhdxPaths += $found }
        }
        $vhdxPaths = @($vhdxPaths | Select-Object -Unique)

        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )

        if ($vhdxPaths.Count -eq 0) {
            Write-LogLine -Log $_log skip "vhdx ファイルが見つかりません"
        } elseif (-not $isAdmin) {
            foreach ($vhdx in $vhdxPaths) {
                $sizeGB = [math]::Round($vhdx.Length / 1GB, 1)
                Write-Host "   $($vhdx.FullName) ($sizeGB GB)" -ForegroundColor White
            }
            Write-LogLine -Log $_log skip "vhdx 圧縮には管理者権限が必要です。管理者として実行してください"
        } elseif ($DryRun) {
            foreach ($vhdx in $vhdxPaths) {
                $sizeGB = [math]::Round($vhdx.Length / 1GB, 1)
                Write-LogLine -Log $_log skip "$($vhdx.FullName) ($sizeGB GB, dry run)"
            }
        } else {
            # fstrim で未使用ブロックをゼロ埋め（これがないと compact が効かない）
            $distros = wsl --list --quiet 2>$null |
                ForEach-Object { ($_ -replace '\x00', '').Trim() } |
                Where-Object { $_ -match '^\S+$' }
            foreach ($distro in $distros) {
                Write-Host "   [$distro] fstrim を実行中..." -ForegroundColor White
                wsl -d $distro --exec sudo fstrim -v / 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-LogLine -Log $_log done "[$distro] fstrim 完了"
                } else {
                    Write-LogLine -Log $_log fail "[$distro] fstrim 失敗（sudo権限を確認してください）"
                }
            }

            # WSL2 を完全にシャットダウン
            Write-Host "   WSL2 をシャットダウンしています..." -ForegroundColor Yellow
            wsl --shutdown 2>$null
            Start-Sleep -Seconds 5

            # Optimize-VHD (Hyper-V / Windows Pro) または diskpart (Windows Home) で圧縮
            $hasOptimizeVHD = Get-Command Optimize-VHD -ErrorAction SilentlyContinue

            foreach ($vhdx in $vhdxPaths) {
                $sizeBeforeGB = [math]::Round($vhdx.Length / 1GB, 1)
                Write-Host "   圧縮中: $($vhdx.FullName) ($sizeBeforeGB GB)" -ForegroundColor White

                try {
                    if ($hasOptimizeVHD) {
                        Optimize-VHD -Path $vhdx.FullName -Mode Full
                    } else {
                        $diskpartScript = @"
select vdisk file="$($vhdx.FullName)"
attach vdisk readonly
compact vdisk
detach vdisk
"@
                        $tmpFile = [System.IO.Path]::GetTempFileName()
                        Set-Content -Path $tmpFile -Value $diskpartScript -Encoding ASCII
                        diskpart /s $tmpFile 2>&1 | Out-Null
                        Remove-Item $tmpFile -ErrorAction SilentlyContinue
                    }

                    # 圧縮後のサイズを取得
                    $vhdxAfter = Get-Item $vhdx.FullName -ErrorAction SilentlyContinue
                    if ($vhdxAfter) {
                        $sizeAfterGB = [math]::Round($vhdxAfter.Length / 1GB, 1)
                        $freedGB = [math]::Round($sizeBeforeGB - $sizeAfterGB, 1)
                        $method = if ($hasOptimizeVHD) { "Optimize-VHD" } else { "diskpart" }
                        Write-LogLine -Log $_log done "$($vhdx.Name): $sizeBeforeGB GB → $sizeAfterGB GB (解放: $freedGB GB) [$method]"
                    }
                } catch {
                    Write-LogLine -Log $_log fail "$($vhdx.Name) の圧縮に失敗: $_"
                }
            }
        }
    } catch {
        Write-LogLine -Log $_log fail "vhdx 圧縮中にエラー: $_"
    }
}

# ---- 4. Windows 一時ファイル削除 ----
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

# ---- 5. 高メモリプロセスの表示（停止はしない）----
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
$sysAfter    = Get-SystemMemoryInfo
$memBeforeGB = [math]::Round($memBefore / 1MB, 1)
$memFreed    = [math]::Round(($memBefore - $sysAfter.UsedKB) / 1KB, 1)
$diskAfter   = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue).FreeSpace

$hasDiskInfo  = $diskBefore -and $diskAfter
if ($hasDiskInfo) {
    $diskBeforeGB = [math]::Round($diskBefore / 1GB, 1)
    $diskAfterGB  = [math]::Round($diskAfter / 1GB, 1)
    $diskFreedGB  = [math]::Round(($diskAfter - $diskBefore) / 1GB, 1)
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor White
Write-Host "  クリーンアップ完了" -ForegroundColor Green

Write-Host "  [メモリ]" -ForegroundColor Cyan
Write-Host "  実行前 : $memBeforeGB GB 使用中" -ForegroundColor White
Write-Host "  実行後 : $($sysAfter.UsedGB) GB 使用中" -ForegroundColor White
if ($memFreed -gt 0) {
    Write-Host "  解放量 : $memFreed MB" -ForegroundColor Green
} else {
    Write-Host "  解放量 : $memFreed MB (OS再利用待ち)" -ForegroundColor Yellow
}

if ($hasDiskInfo) {
    Write-Host "  [ディスク C:]" -ForegroundColor Cyan
    Write-Host "  実行前 : $diskBeforeGB GB 空き" -ForegroundColor White
    Write-Host "  実行後 : $diskAfterGB GB 空き" -ForegroundColor White
    if ($diskFreedGB -gt 0) {
        Write-Host "  回復量 : $diskFreedGB GB" -ForegroundColor Green
    } else {
        Write-Host "  回復量 : $diskFreedGB GB" -ForegroundColor Yellow
    }
}

Write-Host ("=" * 60) -ForegroundColor White

$_log.Add("")
$_log.Add("メモリ: $memBeforeGB GB → $($sysAfter.UsedGB) GB (解放: $memFreed MB)")
if ($hasDiskInfo) {
    $_log.Add("ディスク C: $diskBeforeGB GB → $diskAfterGB GB 空き (回復: $diskFreedGB GB)")
}

# ---- レポート出力 ----
if ($Report) {
    Write-Host ""
    & "$PSScriptRoot\report.ps1" -Notify:$Notify
} elseif ($Notify) {
    Send-SlackNotification -Message ("【Cleanup完了】`n" + ($_log -join "`n"))
}
