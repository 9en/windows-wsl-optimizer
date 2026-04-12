#Requires -Version 5.1
<#
.SYNOPSIS
    WSL2・Docker・プロセス別メモリ使用状況レポートを表示する
.DESCRIPTION
    Windows全体のメモリ状況、WSL2・Docker・devcontainerのメモリ使用量を可視化します。
.EXAMPLE
    .\report.ps1
    .\report.ps1 -Notify
#>

[CmdletBinding()]
param(
    [switch]$Notify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\lib\common.ps1"

# ---- Main ----

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$lines = [System.Collections.Generic.List[string]]::new()

$lines.Add("=" * 60)
$lines.Add("  Windows Memory Optimizer - Report")
$lines.Add("  $timestamp")
$lines.Add("=" * 60)

$sys = Get-SystemMemoryInfo
$lines.Add("")
$lines.Add("[SYSTEM MEMORY]")
$lines.Add("  Total : $($sys.TotalGB) GB")
$lines.Add("  Used  : $($sys.UsedGB) GB   $(Get-MemoryBar -UsedGB $sys.UsedGB -TotalGB $sys.TotalGB)")
$lines.Add("  Free  : $($sys.FreeGB) GB")

$wsl = Get-WslMemory
$lines.Add("")
$lines.Add("[WSL2]")
if ($wsl.Running) {
    $lines.Add("  vmmem : $($wsl.MemMB) MB")
    foreach ($inst in $wsl.Instances) {
        $lines.Add("    - $($inst.Name)  [$($inst.State)]")
    }
} else {
    $lines.Add("  WSL2 is not running (or not installed)")
}

$docker = Get-DockerMemory
$lines.Add("")
$lines.Add("[DOCKER]")
if ($docker.Running) {
    $lines.Add("  Total container memory: $($docker.TotalMB) MB")
    if ($docker.Containers.Count -gt 0) {
        $lines.Add("  Containers ($($docker.Containers.Count) running):")
        foreach ($c in $docker.Containers) {
            $lines.Add("    - $($c.Name)  $($c.Usage)")
        }

        $devcontainers = $docker.Containers |
            Where-Object { $_.Name -match 'devcontainer|vsc-' -or $_.Image -match 'devcontainer' }
        if ($devcontainers) {
            $lines.Add("")
            $lines.Add("[DEVCONTAINERS]")
            foreach ($dc in $devcontainers) {
                $lines.Add("  - $($dc.Name)  [$($dc.Image)]  $($dc.Usage)")
            }
        }
    } else {
        $lines.Add("  No running containers")
    }
} else {
    $lines.Add("  Docker is not running")
}

$lines.Add("")
$lines.Add("[TOP PROCESSES (by memory)]")
foreach ($p in (Get-TopProcesses -Top 10)) {
    $pName = ([string]$p.Name).PadRight(30)
    $pId   = ([string]$p.PID).PadRight(6)
    $pMem  = ([string]$p.MemMB).PadLeft(8)
    $lines.Add("  $pName PID:$pId $pMem MB")
}

$lines.Add("")
$lines.Add("=" * 60)

$report = $lines -join "`n"
Write-Host $report

if ($Notify) {
    Send-SlackNotification -Message $report
}
