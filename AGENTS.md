# Repository Guidelines

## プロジェクト構成とモジュール

このリポジトリは、Windows 上で動かす株価分析ツールです。構成はフラットで、主要ファイルはリポジトリ直下に置かれています。

- `kabu-lab.html`: 現行の KABU LAB アプリ本体。
- `stock-alert.html`: 旧版の株価アラート UI。
- `kabu-lab-proxy.ps1`: KABU LAB 用のローカルプロキシ。Yahoo Finance、TDnet IR、銘柄名取得などを扱います。
- `kabu-proxy.ps1`: 旧版向けの Yahoo Finance プロキシ。
- `start-kabu-lab.bat`、`start-stock-alert.bat`、`start-proxy.bat`、`stop-proxy.bat`: 起動・停止用のバッチファイル。

新しい共通ファイルが必要な場合は、意図が明確でない限り直下へ増やしすぎず、`assets/` などの専用ディレクトリを作って参照元も更新してください。

## ビルド・テスト・開発コマンド

パッケージマネージャーやビルド手順はありません。Windows で直接起動します。

- `.\start-kabu-lab.bat`: ポート `8809` で KABU LAB プロキシを起動し、`kabu-lab.html` を開きます。
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\kabu-lab-proxy.ps1 -Port 8809`: メインプロキシを手動起動します。
- `.\start-stock-alert.bat`: 旧版プロキシをポート `8787` で起動し、`stock-alert.html` を開きます。
- `Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8809/health`: メインプロキシの疎通確認を行います。

## コーディング規約と命名

既存ファイルに合わせ、HTML、CSS、JavaScript、PowerShell、バッチ処理では 2 スペース相当のインデントを基本にしてください。JavaScript は説明的な `camelCase`、PowerShell 関数は既存に合わせた `PascalCase` を優先します。日本語の表示文言は UTF-8 を前提にし、不要な文字コード変更は避けてください。

## テスト方針

自動テスト環境はありません。変更後は `.\start-kabu-lab.bat` を実行し、ヘルスチェック、株価取得、チャート表示、TDnet IR 取得、インポート、エクスポートなど、変更範囲に関係する操作を手動で確認してください。プロキシを変更した場合は、正常系だけでなく不正な入力時のレスポンスも確認します。

## コミットとプルリクエスト

このディレクトリでは Git 履歴を確認できないため、固有のコミット規約は推定できません。コミットメッセージは `Fix TDnet IR parsing` や `Update proxy health check` のように、短い命令形で書いてください。プルリクエストには変更内容、手動テスト結果、影響するポートやエンドポイント、UI 変更がある場合はスクリーンショットを含めます。

## セキュリティと設定

プロキシは `127.0.0.1` に限定してください。任意 URL へ転送できる汎用プロキシにはしないでください。API キーや秘密情報を HTML、PowerShell、バッチファイルに保存しないでください。
