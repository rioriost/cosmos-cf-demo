# Azure Cosmos DB Change Feed デモ

## 概要

このリポジトリは、**Azure Cosmos DB (NoSQL)** の **Change Feed** 機能と
**Azure Container Apps** を用いてリアルタイムなデータ処理パイプラインを
構築する方法を示すサンプルです。デモでは 5 つの IoT センサーを想定し、
それぞれランダムな間隔で温度データを生成します。Change Feed
を購読するサマライザーが最新のデータから統計量を計算し、
ビジュアライザーが集約結果をグラフとして表示します。

Change Feed は Cosmos DB コンテナへの変更を **追記専用のストリーム** と
して公開し、全件検索することなく新しい書き込みや更新を検出できます。
IoT・ゲーム・リアルタイム分析など、イベント駆動型アーキテクチャに
適したパターンです【437749716107481†L47-L66】。

<div align="center">
  <img src="docs/assets/change_feed_overview.png" alt="Change Feed のアーキテクチャ図" width="600" />
  <p><em>図 1 – Change Feed によってイベント駆動型アプリケーションを効率的かつ
  スケーラブルに構築できます【437749716107481†L47-L66】。</em></p>
</div>

## クイックスタート

### 前提条件

* **Azure サブスクリプション** – リソースグループを作成できる権限が必要です。
* **Azure CLI (`az`) と Azure Developer CLI (`azd`)** – これらのツールで
  インフラの構築とデプロイを自動化します。インストール方法は
  [Azure CLI](https://aka.ms/install-azure-cli) と
  [azd ドキュメント](https://aka.ms/azd) を参照してください。
* **Git** – リポジトリをクローンするため。

### デプロイ手順

1. **リポジトリをクローン**:

   ```bash
   git clone <このリポジトリ>
   cd cosmos-cf-demo
   ```

2. **サインインと初期設定**:

   ```bash
   az login
   azd login
   azd init --subscription <サブスクリプションID>
   ```

3. **インフラ構築とデプロイ**:

   ```bash
   azd up
   ```

   `azd up` コマンドは Bicep テンプレート (`infra/main.bicep`) に定義された
   Azure リソースをプロビジョニングし、コンテナイメージをビルド・デプロイ
   します。

4. **ビジュアライザーにアクセス**:

   デプロイ完了後、`visualizer` コンテナアプリの URL が出力されます。
   ブラウザでアクセスすると、各センサーの統計を表示するグラフを閲覧
   できます。新しい集約データが到着すると該当グラフのみが更新され、
   センサー名の横に赤いアイコンが表示されます。

### クリーンアップ

環境を削除するには、次のコマンドを実行します:

```bash
azd down
```

これにより、このデモで作成されたリソースグループおよび Azure リソースが
削除されます。

## アーキテクチャ

このデモでは 3 つのサービスが Azure Container Apps で動作し、
Cosmos DB アカウントに変更フィードを有効化しています。

* **generator** – 5 台のセンサーを模した Python サービスです。
  各センサーは 1〜10 秒のランダムな間隔で温度を測定し、
  `readings` コンテナに `sensor_id`、`temperature`、`timestamp` を含む
  ドキュメントを挿入します。

* **summariser** – `readings` コンテナの change feed を監視する
  Python サービスです。新しい読み取りがあるとそのセンサーの直近
  10 件を取得して最大・最小・平均温度を計算し、結果を
  `summaries` コンテナに書き込みます。Change Feed により全件検索する
  ことなく効率的に処理できます【437749716107481†L47-L66】。

* **visualizer** – Flask アプリケーションで、`summaries` コンテナから
  データを読み取り、Matplotlib を用いてグラフを生成します。
  画面は 2 列レイアウトとなっており、5 つのセンサーそれぞれにグラフを
  表示します。データが更新されると該当センサーのグラフが自動で
  再読み込みされ、名前の横に赤い丸印が表示されます。

データフローは以下の通りです:

1. センサーが `readings` コンテナにデータを書き込みます。
2. Change Feed は書き込みを順番に記録し、サマライザーがこれを
   消費して集計結果を `summaries` コンテナに保存します。
3. ビジュアライザーは `summaries` コンテナを定期的に読み込み、
   グラフを更新します。

## リポジトリ構成

```
cosmos-cf-demo/
├── infra/              # Azure リソースを定義する Bicep テンプレート
├── generator/          # センサー生成サービス
├── summariser/         # 集計サービス (Change Feed プロセッサ)
├── visualizer/         # ビジュアライズサービス (Flask + Matplotlib)
├── docs/               # ドキュメント用アセット (画像)
└── workshop/           # ハンズオンラボ (en と jp)
```

## 設定

インフラ構成は `infra/main.bicep` に記述され、
`infra/main.parameters.json` でパラメータを指定します。主なリソースは次の通りです。

* **Cosmos DB アカウント** – データベース `sensors` とコンテナ
  `readings`、`summaries`、`leases` を含みます。`readings`
  コンテナは `/sensor_id` をパーティションキーとして書き込みを分散
  します。`summaries` コンテナも `/sensor_id` でパーティション分割し、
  集計データを格納します。`leases` コンテナは Change Feed の
  継続トークンを保存します。
* **Azure Container Registry** – コンテナイメージを格納します。
* **Container Apps Environment** – 3 つのサービスをホストします。
  各サービスはマネージド ID を用いて Cosmos DB に安全にアクセスします。

## ライセンス

このプロジェクトは [MIT License](LICENSE) の下で配布されています。自由に
フォークし、目的に合わせてカスタマイズしてください。
