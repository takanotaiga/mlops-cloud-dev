# MLOps Cloud E2Eテスト計画

作成日: 2026-04-28  
対象ワークスペース: `/Users/taiga/Desktop/mlops_cloud_ws`

このドキュメントは、MLOps CloudにEnd-to-Endテストを導入するための計画です。レビュー課題そのものは `REVIEW_FINDINGS.md` に分離しています。

## 1. 目的

このシステムは、UI、SurrealDB、MinIO/S3、非同期バックエンドワーカー、GPU推論が絡みます。ユニットテストだけでは、ユーザー導線やDB/S3/worker連携の破壊を検知できません。

E2Eテストの目的は以下です。

- ユーザー操作がDB/S3へ正しく反映されることを確認する。
- 非同期workerがDBキューを処理し、成果物をS3/DBへ戻すことを確認する。
- レビューで指摘したセキュリティ/仕様不一致の再発を防ぐ。
- PRごとに軽量なsmokeを回し、重いGPU推論はnightly/manualに分離する。

## 2. 基本方針

一気に「本物GPU推論まで全部」を毎PRで回す構成にはしません。重すぎてCIが不安定になります。

3層に分けます。

| 層 | 対象 | 実行頻度 | 目的 |
|---|---|---|---|
| UI E2E | `mlops-cloud-ui` + SurrealDB + MinIO | PR必須 | ブラウザ導線とAPI proxyの確認 |
| Backend Integration | `mlops-cloud-backend` + SurrealDB + MinIO | PR必須/一部main | worker単位のDB/S3連携確認 |
| System E2E | `mlops-cloud` compose | main/nightly/manual | 統合compose全体の確認 |
| GPU E2E | GPU image + 実モデル | nightly/manual/self-hosted | 本物推論の回帰確認 |

## 3. 推奨ツール

### UI

- Playwright
- `@playwright/test`
- Next.js appを `npm run build && npm run start` または `npm run dev` で起動
- SurrealDBとMinIOはDocker serviceで起動

### Backend

- pytest
- testcontainersまたはdocker compose
- boto3でMinIO検証
- SurrealDB clientでDB検証

### System

- Docker Compose
- Playwright smoke
- shell healthcheck

## 4. テスト用fixture

軽量で固定されたテストデータを用意します。

| fixture | 用途 | 条件 |
|---|---|---|
| `sample.jpg` | 画像アップロード | 小サイズ、CIに置けるもの |
| `sample.mp4` | HLS/動画処理 | 2から5秒程度、数MB以下 |
| `result.json` | 推論結果表示 | 小さいJSON |
| `result.parquet` | Parquet分析/表示 | 数十行程度 |
| annotation seed | bbox/label導線 | 小さい固定データ |

注意:

- 大容量動画は通常CIに入れない。
- 本物モデルの重いcheckpointはPR CIに入れない。
- GPU推論はnightly/manualへ分離する。

## 5. Phase 1: UI E2E

対象リポジトリ:

- `mlops-cloud-ui`

目的:

UIの主要導線が、実際のSurrealDB/MinIOに対して動くことを確認します。GPU backendは使いません。

### 5.1 セットアップ

CIで起動するサービス:

- SurrealDB
- MinIO
- Next.js app

必要環境変数:

```env
SURREAL_URL=ws://127.0.0.1:8000/rpc
SURREAL_NS=mlops_e2e
SURREAL_DB=cloud_ui
SURREAL_USER=root
SURREAL_PASS=root
MINIO_ENDPOINT_INTERNAL=http://127.0.0.1:9000
MINIO_REGION=us-east-1
MINIO_ACCESS_KEY_ID=minioadmin
MINIO_SECRET_ACCESS_KEY=minioadmin
MINIO_BUCKET=mlops-e2e
MINIO_FORCE_PATH_STYLE=true
```

### 5.2 追加するnpm scripts

候補:

```json
{
  "test:e2e": "playwright test",
  "test:e2e:ui": "playwright test --ui"
}
```

### 5.3 最初に入れるテスト

#### 5.3.1 Health check

目的:

- UI APIがDB/S3へ接続できること。

検証:

- `GET /api/status`
- `dbOk === true`
- `s3Ok === true`

#### 5.3.2 Dataset upload: image

目的:

- 画像アップロード導線がDB/S3へ反映されること。

手順:

1. `/dataset/upload` を開く。
2. dataset名を入力する。
3. `sample.jpg` を選択する。
4. uploadを実行する。
5. 完了画面になる。
6. `/dataset` に戻る。
7. datasetカードが表示される。
8. SurrealDBの `file` レコードを確認する。
9. MinIOにオブジェクトが存在することを確認する。

#### 5.3.3 Dataset detail and object detail

目的:

- アップロード後の閲覧導線が壊れていないこと。

手順:

1. `/dataset` から対象datasetを開く。
2. ファイルカードが表示される。
3. object detailを開く。
4. 画像プレビューが表示される。

#### 5.3.4 Soft delete

目的:

- UI削除操作が `dead=true` を立てること。

手順:

1. object detailでRemoveを実行する。
2. `file.dead === true` をDBで確認する。

Cleanerによる物理削除はbackend integration側で確認します。

#### 5.3.5 Inference job create

目的:

- 推論ジョブ作成がDBへ正しく反映されること。

手順:

1. dataset fixtureをDBにseedする。
2. `/inference/create` を開く。
3. job名、task、model、datasetを選ぶ。
4. Startする。
5. `/inference/opened-job` に遷移する。
6. `inference_job.status === ProcessWaiting` を確認する。

#### 5.3.6 推論入力制約

目的:

レビュー課題「UIとバックエンド制約不一致」の再発防止。

検証:

- 複数datasetを選べない、または選んでもStartできない。
- 動画なしdatasetではStartできない。
- 複数動画datasetではStartできない。
- ユーザーに理由が表示される。

#### 5.3.7 Training未接続時の挙動

目的:

Training worker未接続問題の明示。

検証:

- Trainingがdisabled/previewならStartできない。
- もしStart可能にするなら、workerが存在し状態が進むことを別E2Eで確認する。

#### 5.3.8 SQL proxy security

目的:

任意SQLプロキシ対策の確認。

修正後に検証:

- 未認証で `/api/db/query` が拒否される。
- 許可されないSQLが拒否される。
- 専用API経由の正規操作は成功する。

## 6. Phase 2: Backend Integration

対象リポジトリ:

- `mlops-cloud-backend`

目的:

バックエンドworkerがSurrealDB/MinIOと連携して期待通りDB/S3を更新することを確認します。

### 6.1 テスト環境

起動サービス:

- SurrealDB
- MinIO

Python側:

- pytest
- boto3
- surrealdb client
- ffmpegが必要なテストはskip可能にする

### 6.2 テスト分類

| 分類 | CI頻度 | 内容 |
|---|---|---|
| fast unit | PR必須 | config/query/status transition等 |
| db/s3 integration | PR必須 | Cleaner、DB repository、S3 wrapper |
| ffmpeg integration | main/nightlyまたはPR optional | HLS、thumbnail、concat |
| gpu inference | nightly/manual | SAMURAI/RT-DETR実行 |

### 6.3 追加するテスト

#### 6.3.1 Config loading

目的:

- `SURREAL_*` / `MINIO_*` が正しく読み込まれること。
- legacy env fallbackも壊れていないこと。

#### 6.3.2 Query helpers

目的:

- `extract_results`
- `first_result`
- status transition
- record id handling

#### 6.3.3 Cleaner

目的:

- `dead=true` と孤児レコードが削除されること。

手順:

1. MinIOへfixture objectをput。
2. SurrealDBへ `file { dead: true, key, thumbKey }` をseed。
3. `cleaner_manager.TaskRunner.task_main()` を1回実行。
4. DBレコード削除を確認。
5. S3オブジェクト削除を確認。

#### 6.3.4 Video manager: thumbnail

目的:

- `thumbKey` のない動画にサムネイルが作られること。

手順:

1. MinIOへ `sample.mp4` をput。
2. DBへ `file` をseed。
3. `_process_missing_thumbnails()` を実行。
4. `file.thumbKey` とS3上のjpgを確認。

#### 6.3.5 Video manager: HLS

目的:

- HLS jobが生成/処理されること。

手順:

1. `file.encode = 'video-none'`, `mime = 'video/mp4'` をseed。
2. `queue_unhls_video_jobs()` を実行。
3. `hls_job.status = queued` を確認。
4. `video_manager.TaskRunner.task_main()` を実行。
5. `hls_job.status = complete` を確認。
6. `hls_playlist` / `hls_segment` とS3オブジェクトを確認。

#### 6.3.6 Inference manager: invalid jobs

目的:

- バックエンド制約違反時に分かりやすく失敗すること。

検証:

- datasetなし
- dataset複数
- 動画なし
- 動画複数

期待:

- `inference_job.status = Faild` または標準化後の `failed`
- `failureReason` が記録される

#### 6.3.7 Inference manager: fake model

目的:

本物GPU推論なしで、ジョブ処理全体を検証する。

方針:

- `ml_module.registry.run_inference_task` をfakeへ差し替える。
- fakeは小さいmp4/json/parquetを生成する。
- `upload_group_results()` が `inference_result` を作ることを確認する。

検証:

- `ProcessWaiting` → `ProcessRunning` → `Completed`
- `progress.steps` が更新される
- S3に成果物がある
- `inference_result.meta.artifact` が期待通り

## 7. Phase 3: System E2E

対象リポジトリ:

- `mlops-cloud`

目的:

統合composeとして最低限動くことを確認します。

### 7.1 Compose smoke

対象サービス:

- `database`
- `object-storage`
- `cloud-ui`

検証:

- `docker compose up -d database object-storage cloud-ui`
- `GET http://127.0.0.1:3000/api/status`
- UIトップがHTTP 200
- `/dataset` がHTTP 200
- `/inference` がHTTP 200

### 7.2 Compose + cv-backend

対象サービス:

- `database`
- `object-storage`
- `cloud-ui`
- `cv-backend`

検証:

- 小さい動画をアップロード
- `hls_job` が作られる
- 一定時間内に `complete`
- `hls_playlist` routeが200

### 7.3 Compose + cleaner

対象サービス:

- `cm-backend`

検証:

- UIから削除
- `dead=true`
- Cleaner実行後にDB/S3から消える

## 8. Phase 4: GPU E2E

対象:

- `mlops-cloud-backend` GPU image
- `mlx-backend`
- 実SAMURAI/RT-DETR pipeline

実行頻度:

- nightly
- manual
- self-hosted GPU runner

検証:

- 1本の短い動画で `samurai-ulr` 推論が完走する。
- `inference_result` に動画/JSON/Parquetが登録される。
- HLS化され、UIで動画再生できる。
- Parquet表示ができる。

CI上の注意:

- checkpoint downloadを毎回しない。
- image cacheを使う。
- テスト時間にtimeoutを設定する。
- 失敗時にworker log、DB dump、S3 object listをartifact化する。

## 9. CI導入案

### 9.1 `mlops-cloud-ui`

既存CI:

- type-check
- build

追加:

- Playwright install
- SurrealDB service
- MinIO service
- app start
- `npm run test:e2e`

PR必須にする範囲:

- health
- upload image
- dataset list/detail
- inference job create
- security regression smoke

### 9.2 `mlops-cloud-backend`

追加:

- `pytest -q tests/unit`
- `pytest -q tests/integration`

PR必須:

- unit
- DB/S3 integration軽量分

main/nightly:

- FFmpeg HLS
- fake inference

manual/nightly GPU:

- real inference

### 9.3 `mlops-cloud`

追加:

- compose smoke workflow
- docker compose up/down
- UI status check

main/nightly推奨:

- compose + cv-backend
- compose + cleaner

## 10. テスト分離とデータ初期化

E2Eはテストごとに独立させます。

推奨:

- dataset名/job名にuuidを付ける。
- SurrealDB namespace/databaseをE2E専用にする。
- MinIO bucketもE2E専用にする。
- テスト開始前にbucketを空にする。
- テスト終了後にDBテーブルを削除する。

例:

```text
dataset: e2e-dataset-<uuid>
job: e2e-infer-<uuid>
bucket: mlops-e2e
namespace: mlops_e2e
database: cloud_ui
```

## 11. レビュー課題との対応表

| レビュー課題 | 必要なE2E |
|---|---|
| 任意SQLプロキシ | 未認証/未許可SQLが拒否される。専用APIは通る。 |
| Webターミナル | 無効時に接続できない。認証なし接続が拒否される。 |
| 推論入力制約 | 複数dataset/複数動画/動画なしをUIで防ぐ。 |
| Training未接続 | 未接続時にStart不可、またはworker接続時に状態が進む。 |
| デフォルト資格情報/公開ポート | prod compose相当でDB/S3直接公開に依存しない。 |
| 状態値不統一 | queued/running/completed/failed/cancelledの表示と遷移を確認。 |
| HLS派生成果物 | original/derivedのDB関係とS3存在を確認。 |

## 12. 最初の実装順

最短で価値が出る順番です。

1. `mlops-cloud-ui` にPlaywrightを導入する。
2. CIでSurrealDB/MinIOを起動する。
3. `/api/status` E2Eを追加する。
4. 画像アップロードE2Eを追加する。
5. dataset list/detail E2Eを追加する。
6. inference job create E2Eを追加する。
7. 推論入力制約E2Eを追加する。
8. backend Cleaner integration testを追加する。
9. backend HLS integration testを追加する。
10. fake inference integration testを追加する。
11. compose smokeを `mlops-cloud` に追加する。
12. GPU nightlyを設計する。

## 13. 完了条件

E2E導入の初期完了条件:

- PRでUI E2E smokeが走る。
- PRでbackend DB/S3 integrationの軽量テストが走る。
- mainまたはnightlyでcompose smokeが走る。
- 失敗時にログとtraceがartifactとして残る。
- レビュー課題の修正に対応する回帰テストが存在する。

この状態になってからP0/P1修正を進めると、既存導線を壊した場合にすぐ検知できます。
