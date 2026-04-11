# WSL2/devcontainer環境のWindowsメモリ最適化ツールを開発する

## 概要

WSL2・devcontainer環境を使い始めてからWindowsの動作が重くなったため、
メモリ使用状況の把握・最適化・定期メンテナンスを自動化するツールをPowerShellで開発する。

## 背景・モチベーション

* リポジトリごとにdevcontainerを立ち上げる運用にしてからWindowsが遅くなった
* WSL2やDockerがメモリを大量消費している可能性がある
* 複数のWindows端末を所持しており、GitHubで管理してどの端末でも使えるようにしたい

## 実現したいこと

* メモリ使用状況のレポート表示（何にどのくらい使っているか可視化）
* ワンコマンドでクリーンアップ実行（キャッシュクリア・メモリ解放・不要プロセス停止）
* タスクスケジューラへの定期実行設定
* WSL2メモリ上限設定（.wslconfig の自動生成・調整）
* 起動中のdevcontainer一覧とメモリ使用量の表示
* 定期実行後にSlack/Discordへレポート通知

## 完了条件

- [ ] PowerShellスクリプトをGitHubリポジトリで管理できる
- [ ] git clone後にセットアップが完結する
- [ ] メモリ使用状況レポートが表示できる
- [ ] ワンコマンドでクリーンアップが実行できる
- [ ] タスクスケジューラに定期実行が登録できる
- [ ] .wslconfig を自動生成・調整できる
- [ ] 起動中devcontainerのメモリ使用量が確認できる
- [ ] Slack or Discord にレポートが通知される

## リポジトリ情報

* リポジトリ名: windows-memory-optimizer
* ディスクリプション: WSL2・devcontainer環境向け Windowsメモリ監視・最適化ツールキット

## 技術的なメモ

* 言語: PowerShell
* 対象環境: Windows + WSL2 + Docker Desktop (devcontainer)
* 通知先: Slack または Discord（Webhook）

## 懸念点・検討事項

- [ ] Docker Desktop と WSL2 backend の両方に対応するか確認
- [ ] Slack/Discord どちらを優先するか（または両対応か）

