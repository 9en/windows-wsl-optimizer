# windows-memory-optimizer

WSL2・devcontainer環境向け Windowsメモリ監視・最適化ツールキット

## 概要

WSL2やDocker Desktop(devcontainer)を多用する開発環境でWindowsのメモリ使用量を
監視・可視化・最適化するPowerShellスクリプト集です。

## ファイル構成

```
windows-memory-optimizer/
├── setup.ps1       — 初期セットアップ（.wslconfig生成・タスクスケジューラ登録）
├── report.ps1      — メモリ使用状況レポート表示
├── cleanup.ps1     — ワンコマンドクリーンアップ
├── notify.ps1      — Slack通知
├── lib/
│   └── common.ps1  — 共通ユーティリティ（メモリ取得・バーグラフ・ログ・Slack送信）
└── README.md
```

## 対象環境

- Windows 10/11
- WSL2
- Docker Desktop（WSL2 backend または Hyper-V backend）

## 前提ソフトウェア

### Git のインストール（任意）

`git clone` でダウンロードする場合は Git が必要です（ZIP ダウンロードのみなら不要）。

#### winget を使う場合（推奨）

```powershell
winget install --id Git.Git -e --source winget
```

インストール後、PowerShell を再起動して `git --version` で確認してください。

#### 手動インストール

1. https://git-scm.com/downloads/win にアクセス
2. **"64-bit Git for Windows Setup"** をダウンロードして実行
3. インストーラーの設定はデフォルトのままで OK
4. インストール後、PowerShell を再起動

---

## クイックスタート

### 1. ダウンロード

タスクスケジューラがスクリプトのフルパスを参照するため、移動しない場所に配置してください。

```powershell
cd $HOME
git clone https://github.com/9en/windows-memory-optimizer.git
cd windows-memory-optimizer
```

> **注意:** フォルダを移動するとタスクスケジューラの登録が壊れます。
> 移動した場合は `.\setup.ps1` を再実行してください。

### 2. セットアップ（管理者権限のPowerShellで実行）

```powershell
# 基本セットアップ（.wslconfig生成 + タスクスケジューラ登録）
.\setup.ps1

# Slack Bot Tokenも一緒に設定する場合
.\setup.ps1 -SlackToken "xoxb-..." -SlackChannel "#general"

# WSLメモリ上限を手動指定する場合（デフォルト: 物理メモリの50%）
.\setup.ps1 -WslMemoryGB 8 -WslProcessors 4
```

### 3. WSL2 を再起動して .wslconfig を反映

```powershell
wsl --shutdown
```

---

## Slack App の設定

Slack通知（`-Notify` オプション）を使う場合は、先にこのセクションの設定を行ってください。

### 必要な環境変数

| 変数名 | 内容 |
|--------|------|
| `SLACK_BOT_TOKEN` | Bot Token (`xoxb-` で始まる文字列) |
| `SLACK_CHANNEL` | 投稿先チャンネル (`#general` または チャンネルID) |

```powershell
# 環境変数を手動設定する場合
[System.Environment]::SetEnvironmentVariable("SLACK_BOT_TOKEN", "xoxb-xxx-yyy-zzz", "User")
[System.Environment]::SetEnvironmentVariable("SLACK_CHANNEL", "#general", "User")
```

設定後、PowerShellを再起動すると反映されます。

### Slack App の作成手順

#### 1. アプリを作成する

1. ブラウザで https://api.slack.com/apps を開く
2. 右上の **"Create New App"** をクリック
3. **"From scratch"** を選択
4. App Name（例: `memory-optimizer`）と投稿先ワークスペースを入力 → **"Create App"**

#### 2. Bot Token スコープを設定する

1. 左メニューの **"OAuth & Permissions"** を開く
2. **"Scopes"** セクションの **"Bot Token Scopes"** まで下にスクロール
3. **"Add an OAuth Scope"** をクリックし、以下を追加:

| スコープ | 用途 |
|---------|------|
| `chat:write` | アプリが参加しているチャンネルへの投稿 |
| `chat:write.public` | 参加していないパブリックチャンネルへの投稿（任意） |

#### 3. ワークスペースにインストールしてトークンを取得する

1. 同じページ上部の **"OAuth Tokens for Your Workspace"** セクションへ
2. **"Install to Workspace"** をクリック
3. 権限確認画面で **"許可する"** をクリック
4. **"Bot User OAuth Token"**（`xoxb-` で始まる文字列）が表示されるのでコピー

#### 4. 投稿先チャンネルにアプリを招待する

Slackのチャンネルを開き、メッセージ入力欄で以下を送信:

```
/invite @memory-optimizer
```

> **注意:** この手順をしないと `not_in_channel` エラーになります。  
> `chat:write.public` スコープを付けた場合、パブリックチャンネルへの招待は不要です。

#### 5. 環境変数に設定する

```powershell
.\setup.ps1 -SlackToken "xoxb-xxxxxxxxxx-xxxxxxxxxx-xxxxxxxxxxxxxxxx" -SlackChannel "#general"
```

または手動で:

```powershell
[System.Environment]::SetEnvironmentVariable("SLACK_BOT_TOKEN", "xoxb-xxxxxxxxxx-...", "User")
[System.Environment]::SetEnvironmentVariable("SLACK_CHANNEL", "#general", "User")
```

#### 6. 動作確認

```powershell
.\notify.ps1 -Message "テスト通知"
```

Slackに通知が届けば設定完了です。

---

## 各スクリプトの使い方

### setup.ps1 — セットアップ

```powershell
# 全オプション
.\setup.ps1 `
    -WslMemoryGB 8 `
    -WslProcessors 4 `
    -SlackToken "xoxb-..." `
    -SlackChannel "#general" `
    -ScheduleTime "20:00"

# .wslconfigだけ生成（タスクスケジューラ不要）
.\setup.ps1 -SkipScheduler

# Slackトークンだけ設定（.wslconfig不要）
.\setup.ps1 -SkipWslConfig -SlackToken "xoxb-..." -SlackChannel "#general"

# 現在の設定状態を確認
.\setup.ps1 -Status
```

`-Status` を付けると、.wslconfig・Slack環境変数・タスクスケジューラの現在の設定を一覧表示します。

### report.ps1 — メモリレポート

```powershell
# レポートを表示
.\report.ps1

# レポートを表示してSlackにも通知
.\report.ps1 -Notify
```

表示内容:
- システム全体のメモリ使用量（グラフ付き）
- WSL2 の vmmem 使用量・起動中ディストリビューション一覧
- Docker コンテナ別メモリ使用量
- 起動中 devcontainer の一覧
- メモリ消費トッププロセス（上位10件）

### cleanup.ps1 — クリーンアップ

```powershell
# 基本実行（WSLキャッシュ + Dockerイメージ/ビルドキャッシュ全削除 + 一時ファイル + DNS）
.\cleanup.ps1

# ドライラン（確認のみ、実際の削除はしない）
.\cleanup.ps1 -DryRun

# クリーンアップ後にレポート表示 + Slack通知
.\cleanup.ps1 -Report -Notify

# 特定の対象をスキップ
.\cleanup.ps1 -SkipWsl              # WSL2のキャッシュ解放をスキップ
.\cleanup.ps1 -SkipDocker           # Docker関連の削除をスキップ
.\cleanup.ps1 -SkipWindowsCache     # Windows一時ファイル/DNS削除をスキップ
.\cleanup.ps1 -SkipPruneBuildCache  # ビルドキャッシュは最近使用分を保持

# 追加の削除オプション
.\cleanup.ps1 -PruneImages          # 未使用Dockerイメージを全て削除（タグ付き含む）
.\cleanup.ps1 -SkipPruneVolumes     # 未使用Dockerボリュームの削除をスキップ
```

実行内容:
1. WSL2 ページキャッシュ解放 + ディスククリーンアップ
   - ページキャッシュ解放 (`echo 3 > /proc/sys/vm/drop_caches`)
   - systemd journalログ縮小(100MB)、aptキャッシュ・不要パッケージ削除
   - 不要snapパッケージ削除、VS Code Serverの古いバージョン削除、/tmpクリア
2. Docker: 停止コンテナ・未使用イメージ(タグなし)・ビルドキャッシュ(全て)・ネットワーク削除 + ディスク使用量表示
   - タグ付きイメージも全削除: `-PruneImages`
   - ビルドキャッシュ全削除をスキップ: `-SkipPruneBuildCache`(最近使用分は保持)
   - ボリューム削除はデフォルト有効(`-SkipPruneVolumes` でスキップ)
3. WSL2 仮想ディスク(vhdx)圧縮 — fstrim → WSL2シャットダウン → `Optimize-VHD` または `diskpart` で圧縮し、Cドライブの空きを回復(管理者権限が必要)
4. Windowsの一時ファイル削除（`%TEMP%`, `%TMP%`, `C:\Windows\Temp`）
5. DNS キャッシュクリア
6. 高メモリプロセスの表示のみ（自動停止はしない）

### notify.ps1 — Slack通知

```powershell
# 環境変数のトークン・チャンネルで送信
.\notify.ps1 -Message "テストメッセージ"

# パラメータで直接指定
.\notify.ps1 -Token "xoxb-..." -Channel "#alerts" -Message "テスト"

# タイトルと色を変更（good=緑 / warning=黄 / danger=赤 / #RRGGBB）
.\notify.ps1 -Message "警告" -Title "Memory Alert" -Color "warning"
```

Slack App の Bot Token (`xoxb-...`) と `chat.postMessage` API を使って投稿します。

---

## タスクスケジューラ

`setup.ps1` を管理者権限で実行すると、以下のタスクが登録されます。
予定時刻にPCがスリープ・シャットダウンしていた場合は、次回PC起動時に自動実行されます（`StartWhenAvailable`）。

| タスク名 | 実行タイミング | 内容 |
|---------|-------------|------|
| `MemoryOptimizer` | 毎日 20:00 | クリーンアップ → レポート生成 → Slack通知 |

確認・編集:
```powershell
# タスク確認
Get-ScheduledTask -TaskName "MemoryOptimizer"

# タスクスケジューラGUIを開く
taskschd.msc
```

---

## .wslconfig について

`setup.ps1` が `%USERPROFILE%\.wslconfig` を自動生成します。
既存のファイルがある場合は `.wslconfig.bak_YYYYMMDDHHMMSS` としてバックアップされます。

生成される設定例（物理メモリ16GB・12コアの場合）:

```ini
[wsl2]
memory=8GB        # 物理メモリの50%
processors=6      # CPUコアの50%
swap=2GB          # メモリの25%
pageReporting=true
localhostForwarding=true
```

---

## 物理メモリ・コア数の確認方法

`setup.ps1` はセットアップ時に自動取得しますが、手動で確認したい場合は以下のコマンドを使います。

### PowerShell で確認する（推奨）

```powershell
# 物理メモリ (GB)
$os = Get-CimInstance Win32_OperatingSystem
[math]::Round($os.TotalVisibleMemorySize / 1MB, 1)

# 論理コア数（スレッド数）
(Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

# 物理コア数
(Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum
```

まとめて確認する場合:

```powershell
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Write-Host "メモリ     : $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
Write-Host "論理コア数 : $($cs.NumberOfLogicalProcessors)"
Write-Host "物理コア数 : $((Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum)"
Write-Host "CPU名      : $($cpu.Name)"
```

### タスクマネージャーで確認する（GUI）

1. `Ctrl + Shift + Esc` → **"パフォーマンス"** タブ
2. **"CPU"** → 右下に「コア」「論理プロセッサ」が表示される
3. **"メモリ"** → 右上に搭載メモリ量が表示される

### .wslconfig の推奨値の目安

| 物理メモリ | WSL2 推奨上限 (`memory`) |
|-----------|------------------------|
| 8 GB      | 4 GB                   |
| 16 GB     | 8 GB                   |
| 32 GB     | 16 GB                  |
| 64 GB     | 32 GB                  |

`processors` は論理コア数の半分程度を目安にしてください。  
`setup.ps1` はこれらを自動計算して設定します（`-WslMemoryGB` で上書き可能）。

---

## トラブルシューティング

**ExecutionPolicy エラーが出る場合**
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Docker コマンドが見つからない場合**

Docker Desktop がインストールされ、起動していることを確認してください。

**WSL2 のメモリが解放されない場合**

`pageReporting=true` の設定後、WSL2 を再起動してください:
```powershell
wsl --shutdown
```
その後、Windows のメモリが徐々に解放されます（数分かかることがあります）。
