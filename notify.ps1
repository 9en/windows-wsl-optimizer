#Requires -Version 5.1
<#
.SYNOPSIS
    Slack App トークンを使ってメッセージを送信する
.DESCRIPTION
    Slack Bot Token (xoxb-...) と chat.postMessage API でメッセージを投稿します。
    トークンは環境変数 SLACK_BOT_TOKEN、チャンネルは SLACK_CHANNEL で設定します。
.EXAMPLE
    .\notify.ps1 -Message "テスト通知"
    .\notify.ps1 -Message "警告" -Color "warning"
    .\notify.ps1 -Token "xoxb-..." -Channel "#alerts" -Message "テスト"
#>

[CmdletBinding()]
param(
    # Slack Bot Token (xoxb-...) 省略時は環境変数 SLACK_BOT_TOKEN を使用
    [string]$Token,
    # 投稿先チャンネル (#channel-name または channel ID) 省略時は環境変数 SLACK_CHANNEL を使用
    [string]$Channel,
    [Parameter(Mandatory)]
    [string]$Message,
    [string]$Title = "Windows Memory Optimizer",
    # good (緑) / warning (黄) / danger (赤) または #RRGGBB
    [string]$Color = "good"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\lib\common.ps1"

# スタンドアロン実行時はトークン・チャンネル未設定をエラーにする
$resolvedToken   = if ($Token)   { $Token }   else { $env:SLACK_BOT_TOKEN }
$resolvedChannel = if ($Channel) { $Channel } else { $env:SLACK_CHANNEL   }

if (-not $resolvedToken) {
    Write-Error "Slack Bot Token が指定されていません。-Token パラメータまたは環境変数 SLACK_BOT_TOKEN を設定してください。"
    exit 1
}
if (-not $resolvedChannel) {
    Write-Error "投稿先チャンネルが指定されていません。-Channel パラメータまたは環境変数 SLACK_CHANNEL を設定してください。"
    exit 1
}

Send-SlackNotification -Token $resolvedToken -Channel $resolvedChannel `
    -Message $Message -Title $Title -Color $Color
