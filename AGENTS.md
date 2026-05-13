# Repository Guidelines

## プロジェクト構成とモジュール

このリポジトリは、Windows 上で動かす株価分析ツールです。リポジトリ直下は起動用バッチを中心にし、アプリ本体は用途別フォルダへ分けています。

- `start-kabu-lab.bat`: KABU LAB の起動用バッチファイル。
- `start-stock-alert.bat`、`start-proxy.bat`、`stop-proxy.bat`: 下落アラート用アプリの起動/停止用バッチファイル。
- `kabu-lab/`: 現行の KABU LAB アプリ本体、プロキシ、朝ニュース関連ファイルを置きます。
- `kabu-lab/kabu-lab.html`: KABU LAB アプリ本体。
- `kabu-lab/kabu-lab-proxy.ps1`: KABU LAB 用のローカルプロキシ。Yahoo Finance、TDnet IR、銘柄名取得などを扱います。
- `stock-alert/`: 下落アラート用アプリ本体と旧プロキシを置きます。旧ファイル扱いで削除しないでください。
- `tools/`: 文字コードチェックなど、開発・保守用スクリプトを置きます。

新しい共通ファイルが必要な場合は、意図が明確でない限り直下へ増やしすぎず、用途に合う専用ディレクトリを作って参照元も更新してください。リポジトリ直下へ追加するのは、原則としてユーザーが直接クリックする `.bat` ファイルと管理ファイルだけにしてください。

## ビルド・テスト・開発コマンド

パッケージマネージャーやビルド手順はありません。Windows で直接起動します。

- `.\start-kabu-lab.bat`: ポート `8809` で KABU LAB プロキシを起動し、`kabu-lab/kabu-lab.html` を開きます。
- `.\start-stock-alert.bat`: ポート `8787` で下落アラート用プロキシを起動し、`stock-alert/stock-alert.html` を開きます。
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\kabu-lab\kabu-lab-proxy.ps1 -Port 8809`: メインプロキシを手動起動します。
- `Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8809/health`: メインプロキシの疎通確認を行います。
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\check-encoding.ps1`: 日本語表示ファイルの UTF-8 と文字化け疑い文字を確認します。

## コーディング規約と命名

既存ファイルに合わせ、HTML、CSS、JavaScript、PowerShell、バッチ処理では 2 スペース相当のインデントを基本にしてください。JavaScript は説明的な `camelCase`、PowerShell 関数は既存に合わせた `PascalCase` を優先します。日本語の表示文言は UTF-8 を前提にし、不要な文字コード変更は避けてください。

## 整理整頓

コードライブラリを常にクリーンに保ってください。テンポラリファイル、デッドコード、デッドファイル、不要なフォルダやサブフォルダを残さないでください。検証用に一時ファイルを作った場合は、作業完了前に削除します。生成データや実行結果はコード本体と混ぜず、必要性が明確なものだけを残します。作業後は `git status --short --untracked-files=all` と関連キーワード検索で、不要ファイルや未使用参照が残っていないことを確認してください。

## テスト方針

自動テスト環境はありません。変更後は `.\start-kabu-lab.bat` を実行し、ヘルスチェック、株価取得、チャート表示、TDnet IR 取得、インポート、エクスポートなど、変更範囲に関係する操作を手動で確認してください。プロキシを変更した場合は、正常系だけでなく不正な入力時のレスポンスも確認します。文字列やファイル配置を変更した場合は `.\tools\check-encoding.ps1` も実行してください。

## コミットとプルリクエスト

このディレクトリでは Git 履歴を確認できないため、固有のコミット規約は推定できません。コミットメッセージは `Fix TDnet IR parsing` や `Update proxy health check` のように、短い命令形で書いてください。プルリクエストには変更内容、手動テスト結果、影響するポートやエンドポイント、UI 変更がある場合はスクリーンショットを含めます。

## セキュリティと設定

プロキシは `127.0.0.1` に限定してください。任意 URL へ転送できる汎用プロキシにはしないでください。API キーや秘密情報を HTML、PowerShell、バッチファイルに保存しないでください。
