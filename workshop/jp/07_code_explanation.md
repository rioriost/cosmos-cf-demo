# 7. コード解説

このセクションでは、デモを構成する各 Python サービスの重要な部分
を取り上げます。コードの理解は、同様のパターンを自分の用途に
適用する際に役立ちます。

## Generator

ジェネレーターサービスは 5 つのセンサーを模倣します。
各センサーは独立したスレッドで動作し、1〜10 秒のランダムな間隔で温度を生成します:

```python
def producer(sensor_id: str, container):
    while True:
        interval = random.randint(1, 10)
        time.sleep(interval)
        temp_c = round(random.uniform(15.0, 40.0), 2)
        now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        doc = {
            "id": str(uuid.uuid4()),
            "sensor_id": sensor_id,
            "temperature": temp_c,
            "timestamp": now
        }
        result = container.upsert_item(doc)
        print(f"[{now}] sensor={sensor_id} wrote id={result.get('id')} temp={result.get('temperature')}")
```

各センサー用にスレッドが起動され、main スレッドは無限ループで待機します。
Container App に割り当てられたマネージド ID で Cosmos DB クライアントに認証します。

この実装に関して、いくつか補足します。

* **ランダムな送信間隔** – 各センサーは 1〜10 秒の間隔で待機してからデータを送信します。
  これは実際の IoT デバイスが不規則なタイミングでデータを送る状況を模倣しています。
  指数分布やポアソン分布を用いてバースト的なトラフィックをシミュレーションすることもできます。
* **ユニーク ID とタイムスタンプ** – `uuid.uuid4()` を使用した `id` はすべてのセンサー間で一意となり、`upsert_item` を使ってもドキュメントの重複書き込みを防げます。
  ISO8601 形式のタイムスタンプは可読性を高めますが、Cosmos DB は `datetime` 型も扱えるため、範囲クエリを行う場合は `datetime` 型を検討してください。
* **冪等な書き込み** – `upsert_item` は既に存在する `id` のドキュメントがあれば更新し、なければ挿入します。
  本デモでは毎回新しい ID を生成しているため `upsert` は `create` と同等ですが、ネットワーク障害などでリトライが発生しても重複が生じません。

ランダムなデータ生成の代わりに実際のセンサー値を使用する場合は、シリアルポートや MQTT ブローカー、Azure IoT Hub からデータを読み取り、`container.upsert_item()` に渡します。
パーティションキーの選択と認証方法は変わりません。

## Summariser

サマライザーは `readings` コンテナの Change Feed を監視します。
新しい項目が検出されると、センサーごとに最新 10 件のデータを取得して統計値を計算し、結果を `summaries` コンテナに書き込みます:

```python
def summarise_sensor(sensor_id: str, readings_container, summary_container):
    query = (
        "SELECT TOP 10 c.timestamp, c.temperature FROM c WHERE c.sensor_id = @sid "
        "ORDER BY c.timestamp DESC"
    )
    items = list(readings_container.query_items(
        query=query,
        parameters=[{"name": "@sid", "value": sensor_id}],
        enable_cross_partition_query=True,
    ))
    temps = [it.get("temperature") for it in items if isinstance(it.get("temperature"), (int, float))]
    if temps:
        summary = {
            "id": str(uuid.uuid4()),
            "timestamp": utc_now_str(),
            "sensor_id": sensor_id,
            "max_temp": max(temps),
            "min_temp": min(temps),
            "avg_temp": round(mean(temps), 2),
        }
        summary_container.upsert_item(summary)
        return summary
```

`read_changes` 関数は Change Feed からバッチを取得し、更新された継続トークンを返します。
進捗は `leases` コンテナのリースドキュメントに保存され、再起動後も同じ位置から読み取りを続けられます。

実装上のポイントをいくつか挙げます。

* **効率的なクエリ** – `summarise_sensor` の SQL クエリは特定のセンサーの最新 10 件を `timestamp` 降順で取得します。
  `readings` は `/sensor_id` でパーティション分割されているため、`sensor_id` でフィルタリングすることでクロスパーティション スキャンを避けています。
* **入力検証** – リスト内包表記で数値でない `temperature` を除外し、不正なペイロードを処理しないようにしています。
  実際のセンサー連携ではデータの正規化やバリデーションを行い、例外を防止してください。
* **冪等な集計** – Change Feed 処理は **少なくとも 1 回** 配信のため、同じイベントが複数回届く可能性があります。
  サマライザーは同じデータを再処理しても整合性が保たれるように設計する必要があります。
  例えば、サマリドキュメントに `last_processed` タイムスタンプを持たせ、それより古い読み取りは無視するなどの工夫が考えられます。
* **並列処理** – 本デモでは単一スレッドで処理していますが、Change Feed プロセッサライブラリを使用すれば複数インスタンスでパーティションを分散処理できます。
  リースドキュメントが自動的に再バランスされるため、負荷に応じてスケールアウトできます。

## Visualiser

ビジュアライザーは Flask アプリケーションで、`summaries` コンテナからデータを読み込んで **matplotlib** でグラフを作成します。
ホームページでは各センサー用の画像をグリッド状に配置し、JavaScript で更新を検知して該当グラフのみを更新します:

```python
@app.route('/')
def index():
    # 各センサー用の画像をグリッドに配置
    # /api/summary-timestamps を 2 秒ごとにポーリングして更新を検知
    ...

@app.route('/plot/<sensor_id>.png')
def plot_png(sensor_id):
    image_bytes = create_plot(sensor_id)
    return Response(image_bytes, mimetype='image/png')

@app.route('/api/summary-timestamps')
def api_summary_timestamps():
    # 各センサーの最新サマリの timestamp を返します
```

`create_plot` 関数は指定されたセンサーの最新サマリを読み込み、平均値・最大値・最小値の折れ線グラフを生成して PNG として返します。
データが更新されると、センサー名の横に赤い丸印が表示されます。

ビジュアライザーは Change Feed ではなく `summaries` コンテナをクエリし、表示専用の **マテリアライズドビュー** を活用しています。
これは下流サービスがソースデータではなく加工済みデータにアクセスする一般的なパターンです。
matplotlib には `Agg` バックエンドを指定し、画像をメモリ上でレンダリングしてレスポンスとして返しています。
チャート数が増えたり更新頻度が高い場合は、集計処理をサマライザー側で増やしたり、プロット画像をキャッシュして負荷を軽減する工夫が有効です。

## ローカル実行

このラボは Azure へのデプロイを前提としていますが、ローカルでサービスを実行して開発やテストを行うこともできます。
同梱のDockerfile を使ってイメージをビルドするか、環境変数を設定してPython スクリプトを直接実行してください。

## 分散並行パターン

コード例をさらに発展させる際には、以下のような並行パターンの採用を検討できます。

* **タスクキュー** – サマライザーの処理をメモリ内または分散キュー（Azure Queue Storage や RabbitMQ など）に追加し、ワーカーが順次取得して実行します。
  これによりジェネレーターとサマライザーの結合度が下がり、負荷に応じたスケールが可能になります。
* **非同期 / await とイベントループ** – Azure SDK for Python や Flask は非同期操作に対応しています。
  サマライザーを `async def` 関数に書き換え、`aiohttp` や `fastapi` を使うことで、多数のセンサーからの入力を効率的に処理できます。
* **冪等な処理** – サマリー文書の ID を `sensor_id` とタイムスタンプから決定論的に生成し (`f"{sensor_id}-{timestamp}"` など)、`upsert` を利用して複数インスタンスが同じイベントを処理しても重複しないようにします。

## 高度なエラーハンドリングとレジリエンス

本番環境では様々な故障に備える必要があります。

* **一時的な障害へのリトライ** – Cosmos DB 呼び出しをリトライ／バックオフ機構でラップします（SDK に設定可能なリトライポリシーがあります）。
  長時間の障害時は指数バックオフし、アラートを上げます。
* **ポイズンメッセージ** – あるドキュメントが繰り返し失敗を引き起こす場合は、それをデッドレターキューに移動するか、エラーフラグを付けてスキップし、パイプライン全体が停止しないようにします。
* **サーキットブレーカー** – サマライザーが依存するサービス（Cosmos DB など）に失敗が続いた場合は回路をオープンにし、一定時間後にリトライするようなパターンを実装します。

## 計測と可観測性

ログ出力とトレーシングに加えて、独自のメトリクスを収集するとボトルネックの特定に役立ちます。

* **カスタムメトリクス** – 1 秒あたりの読み取り処理件数、センサーごとのスライディングウィンドウのサイズ、サマライザーループごとの RU 消費量などを記録し、StatsD や Azure Monitor にエクスポートします。
* **構造化ログ** – `sensor_id` や `reading_id`、処理時間などのフィールドを含む JSON 形式でログを出力すると、Log Analytics などで検索や集計がしやすくなります。
* **例外の関連付け** – ジェネレーターやサマライザーで未処理例外が発生した場合は、`correlation_id` などをログに含めて、サービス間でのデバッグを容易にします。

## 環境設定の管理

アプリが大きくなると設定値（データベース名やコンテナ名、ウィンドウサイズなど）が増えていきます。
コードにハードコーディングせず、設定ファイルや環境変数に外部化しましょう。
**Dapr Secrets API** や **Azure App Configuration** を利用すると、デプロイの再実行なしに設定を動的に更新できます。
また、開発・検証・本番といった環境ごとに設定を切り替えるのにも役立ちます。
