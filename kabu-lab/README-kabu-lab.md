# KABU LAB

Windows上でローカル実行する株価・IR確認アプリです。既存の外部株アプリは使わず、`kabu-lab.html` とローカルプロキシで動作します。

## ファイル

- `kabu-lab.html`
  - KABU LAB本体です。
- `kabu-lab-proxy.ps1`
  - 株価、チャート、TDnet IR、JPX決算予定日、朝ニュース取得用のローカルプロキシです。
- `..\start-kabu-lab.bat`
  - プロキシをポート`8809`で起動し、HTML画面を開きます。
- `test-kabu-lab.ps1`
  - 主要エンドポイントの簡易診断スクリプトです。

## 主な機能

- 日本株 / 米国株の登録
- 株価、PER、PBR、EPS、時価総額の表示
- RSI、SMA、MACD、支持線/抵抗線などのテクニカル分析
- TDnet IRの自動取得
- JPX公式Excelからの次回決算発表予定日取得
- 決算日ベースのウォッチリスト自動整理
- 保有銘柄、決算前後、取得エラー、古い価格/IRを集約する朝チェック
- 決算重視のローカル分析レポート生成
- 決算短信、決算説明資料、業績修正/配当IR向けのChatGPT貼り付け用プロンプト作成
- Codex/ChatGPT向けAI分析依頼JSONコピーと、AI回答JSON/Markdown貼り付け反映
- AI回答メモ、IR差分ビュー、分析チェックリスト、Bull/Bear/Watchメモ
- 保有銘柄、お気に入り、その他銘柄の分類
- Yahoo掲示板と株探ページへの外部リンク
- JSONエクスポート / インポート

## 起動方法

```powershell
.\start-kabu-lab.bat
```

上記はリポジトリ直下から実行します。

正常に起動すると、ローカルプロキシとHTML画面が開きます。接続表示が `127.0.0.1:8809 / v2026-05-13.1` なら最新版です。

## 使い方

1. 銘柄コードを追加します。
2. `価格/分析更新` で株価、基本指標、JPX決算予定日、テクニカル指標を取得します。
3. 日本株は `IR一括更新` でTDnetの直近31日分を取得します。
4. 銘柄ボードの `決算ウォッチリスト` で、本日/明日、7日以内、14日以内、決算後要確認の銘柄を確認します。
5. 決算後要確認の銘柄は、分析チェックリスト、決算IR、AI回答メモ、ステータスを埋めます。
6. CodexやChatGPTで深掘りする場合は、`Codex依頼JSONコピー`で依頼を渡し、回答JSON/Markdownを回答欄に貼り付けて保存します。

## 診断

プロキシ起動後に、主要な取得機能をまとめて確認できます。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\kabu-lab\test-kabu-lab.ps1
```

`health` と入力検証は必須チェックです。JPX、Yahoo、TDnetは外部通信に依存するため、失敗時は `WARN` として表示されることがあります。

## 厳格モード

Yahoo Japan銘柄ページなどのHTMLフォールバックを避けたい場合は、プロキシを厳格モードで起動できます。通常より取得できるデータは減りますが、データ元を絞れます。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\kabu-lab\kabu-lab-proxy.ps1 -Port 8809 -StrictSources
```

または環境変数 `KABU_LAB_STRICT_SOURCES=1` を設定して起動します。

## データソース

- 次回決算発表予定日: JPX公式の決算発表予定日Excel
- 株価、PER/PBR/EPS、チャート: Yahoo Finance系エンドポイント
- IR: TDnet公開ページを主対象にし、取得漏れがある場合はYahoo Finance disclosureを補助的に参照
- 朝ニュース: TDnet、EDINET、Yahoo Finance、X反応、株価ランキングなどを分類して表示

## セキュリティ

- プロキシは `127.0.0.1` のみで待ち受けます。
- 任意URLへ転送できる汎用プロキシではありません。
- JPX決算予定日はJPX公式の `.xlsx` URLだけを許可し、サイズ上限と1日キャッシュを入れています。
- IR PDFリンクは許可ドメインに限定しています。
- 厳格モードでは、Yahoo Japan銘柄ページやYahoo disclosureのHTML補完を使いません。
- APIキーや秘密情報は保存しません。
- 保有銘柄、メモ、AI回答メモはブラウザの`localStorage`に平文保存されます。共用PCでは注意してください。

## 注意

このアプリは投資判断を補助する分析材料を作るためのものです。最終判断は必ずIR本文、決算短信、公式資料で確認してください。
