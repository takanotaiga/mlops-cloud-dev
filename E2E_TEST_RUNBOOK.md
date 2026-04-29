# MLOps Cloud E2E Test Runbook

作成日: 2026-04-28  
対象ワークスペース: `/home/taiga/mlops-cloud-dev`

このドキュメントは、`E2E_TEST_PLAN.md` で定義した E2E テストの実装後の実行方法、検証内容、運用上の注意をまとめる runbook です。

## 1. 位置づけ

`E2E_TEST_PLAN.md` は導入計画です。  
この `E2E_TEST_RUNBOOK.md` は、開発者が実際にテストを走らせるための手順書です。

主な用途:

- ローカル開発で E2E を再実行する。
- CI/manual/nightly に載せるコマンドを確認する。
- 各 Phase が何を検証しているか確認する。
- 失敗時にどこを見るべきか確認する。

## 2. 実装場所

E2E 実装は `mlops-cloud` リポジトリ配下に集約しています。

| 種別 | パス |
|---|---|
| compose 定義 | `mlops-cloud/e2e/compose.phase*.yml` |
| Playwright runner | `mlops-cloud/e2e/Dockerfile` |
| Playwright tests | `mlops-cloud/e2e/tests/` |
| backend pytest tests | `mlops-cloud/e2e/phase2/` |
| GPU pytest tests | `mlops-cloud/e2e/phase4/` |
| fixtures | `mlops-cloud/e2e/fixtures/` |
| e2e package | `mlops-cloud/e2e/package.json` |

補足:

- `mlops-cloud-ui` は Dockerfile から build します。
- `mlops-cloud-backend` は `Dockerfile.base` または `Dockerfile.gpu` から build します。
- SurrealDB / MinIO / Playwright base image は外部 image を pull します。
- DB は SurrealDB `memory`、Object Storage は MinIO `tmpfs` のため、compose 起動ごとに状態がリセットされます。

## 3. 前提条件

必須:

- Docker / Docker Compose v2
- ネットワークアクセス
- `test-image.jpeg` と `test-video.mp4` が `mlops-cloud/e2e/fixtures/` に存在すること

Phase4 のみ追加で必須:

- NVIDIA GPU
- NVIDIA container runtime
- `docker run --rm --gpus all <image> nvidia-smi` が成功すること
- 実 SAMURAI/RT-DETR pipeline を走らせる時間と GPU メモリ

GPU runtime 確認例:

```bash
docker run --rm --gpus all mlops-cloud-backend-gpu:dev nvidia-smi
```

## 4. 共通ルール

実行ディレクトリは `mlops-cloud` です。

```bash
cd /home/taiga/mlops-cloud-dev/mlops-cloud
```

各 Phase の実行後は、原則 `down -v` で片付けます。

```bash
docker compose -f e2e/compose.phaseX.yml down -v
```

compose 構文だけ確認する場合:

```bash
docker compose -f e2e/compose.phase1.yml config >/tmp/phase1.config
docker compose -f e2e/compose.phase2.yml config >/tmp/phase2.config
docker compose -f e2e/compose.phase3.yml config >/tmp/phase3.config
docker compose -f e2e/compose.phase4.yml config >/tmp/phase4.config
```

## 5. Phase 1: UI E2E

対象:

- `mlops-cloud-ui`
- SurrealDB
- MinIO
- Playwright

実行コマンド:

```bash
cd /home/taiga/mlops-cloud-dev/mlops-cloud
docker compose -f e2e/compose.phase1.yml up --build --abort-on-container-exit --exit-code-from e2e e2e
docker compose -f e2e/compose.phase1.yml down -v
```

検証内容:

- `/api/status` が SurrealDB / MinIO に接続できること
- dataset image upload が UI から完了すること
- `file` レコードが SurrealDB に作成されること
- upload object が MinIO に存在すること
- dataset detail / object detail の画像プレビューが表示されること
- soft delete で `file.dead === true` になること
- inference job 作成で `inference_job.status === ProcessWaiting` になること
- browser から `/api/db/query` で任意 SQL を実行できないこと
- `/api/db/query` が allowlist operation と入力検証で動くこと

実装ファイル:

- `e2e/tests/health.spec.ts`
- `e2e/tests/dataset.spec.ts`
- `e2e/tests/inference.spec.ts`
- `e2e/tests/security.spec.ts`

既知の `fixme` / skip:

| テスト | 理由 |
|---|---|
| inference 複数 dataset 制約 | UI 側の制約実装がまだ固定されていないため |
| inference 動画数制約 | UI と backend の仕様統一待ち |
| training disabled / preview | Training worker 接続仕様が未確定のため |

直近の実行結果:

- `8 passed`
- `3 skipped`

## 6. Phase 2: Backend Integration

対象:

- `mlops-cloud-backend`
- SurrealDB
- MinIO
- pytest

実行コマンド:

```bash
cd /home/taiga/mlops-cloud-dev/mlops-cloud
docker compose -f e2e/compose.phase2.yml up --build --abort-on-container-exit --exit-code-from backend-test backend-test
docker compose -f e2e/compose.phase2.yml down -v
```

検証内容:

- `SURREAL_*` / `MINIO_*` env config loading
- legacy env fallback
- SurrealDB query response helper
- record id leaf extraction
- HLS job status transition
- inference job status transition
- Cleaner による `dead=true` file の DB/S3 削除
- Cleaner による orphan annotation の DB/S3 削除
- inference runner の入力制約
- dataset なし job の拒否
- dataset 複数 job の拒否
- 動画なし dataset の拒否
- 複数動画 dataset の拒否
- 単一動画 dataset の受理
- hardware metric のCPU/GPU record shape
- mocked NVML GPU metrics の収集

実装ファイル:

- `e2e/phase2/conftest.py`
- `e2e/phase2/test_config.py`
- `e2e/phase2/test_query_helpers.py`
- `e2e/phase2/test_cleaner.py`
- `e2e/phase2/test_inference_invalid_jobs.py`
- `e2e/phase2/test_hardware_metrics.py`

直近の実行結果:

- `18 passed`
- skip なし

## 7. Phase 3: System E2E

対象:

- `mlops-cloud` compose
- `cloud-ui`
- SurrealDB
- MinIO
- Playwright smoke

実行コマンド:

```bash
cd /home/taiga/mlops-cloud-dev/mlops-cloud
docker compose -f e2e/compose.phase3.yml up --build --abort-on-container-exit --exit-code-from system-e2e system-e2e
docker compose -f e2e/compose.phase3.yml down -v
```

検証内容:

- `GET /api/status`
- `dbOk === true`
- `s3Ok === true`
- `/` が HTTP 200
- `/dataset` が HTTP 200
- `/inference` が HTTP 200
- `hm-backend` が `hardware_metric.system.cpu_percent` と memory 情報を記録すること

実装ファイル:

- `e2e/tests/system.spec.ts`

直近の実行結果:

- `2 passed in 668ms`
- skip なし

## 8. Phase 4: GPU E2E

対象:

- `mlops-cloud-backend` GPU image
- `mlx-backend`
- `cv-backend`
- `cloud-ui`
- `hm-backend`
- SurrealDB
- MinIO
- 実 `samurai-ulr` pipeline。`PHASE4_MODEL=t260-ulr` で T260-ULR pipeline に切り替え可能。

実行頻度:

- manual
- nightly
- self-hosted GPU runner

実行コマンド:

```bash
cd /home/taiga/mlops-cloud-dev/mlops-cloud
docker compose -f e2e/compose.phase4.yml up --build --abort-on-container-exit --exit-code-from phase4-test phase4-test
docker compose -f e2e/compose.phase4.yml down -v
```

検証内容:

- `test-video.mp4` を MinIO に seed
- `file` レコードを SurrealDB に seed
- `annotation.category = 'sam2_key_bbox'` の bbox seed を作成
- `inference_job.model = 'samurai-ulr'` または `PHASE4_MODEL` で指定した model の job を作成
- `mlx-backend` が以下を完走すること
- SAM2 tracking
- DETR training
- model export / export skip
- DETR inference
- result upload
- `inference_job.status === Completed`
- `progress.steps` が主要 step で `completed`
- `inference_result` に `plot_video` が登録されること
- `inference_result` に `results_parquet` が登録されること
- それぞれの S3 object が存在すること
- `cv-backend` が result video を HLS 化すること
- `hls_playlist` / `hls_segment` が登録されること
- HLS object が S3 に存在すること
- UI `/api/status` / `/inference/opened-job` / `/inference/opened-job/analysis` が HTTP 200
- `hardware_metric.system.cpu_percent` が記録されること
- `hardware_metric.gpus[]` にGPU名とVRAM容量が記録されること

実装ファイル:

- `e2e/phase4/conftest.py`
- `e2e/phase4/test_gpu_samurai_pipeline.py`
- `e2e/phase4/test_hardware_metrics_gpu.py`

オプション:

```bash
PHASE4_TIMEOUT_SECONDS=7200 docker compose -f e2e/compose.phase4.yml up --build --abort-on-container-exit --exit-code-from phase4-test phase4-test
PHASE4_REQUIRE_SCHEMA_JSON=1 docker compose -f e2e/compose.phase4.yml up --build --abort-on-container-exit --exit-code-from phase4-test phase4-test
```

補足:

- 現状の backend は schema JSON artifact を必ず upload する実装ではないため、JSON artifact の検証は `PHASE4_REQUIRE_SCHEMA_JSON=1` の opt-in にしています。
- Phase4 は重いため PR 必須にはしません。

直近の実行結果:

- `2 passed in 152.41s`
- skip なし

## 9. Fixture

現在使う fixture:

| file | 配置 | 用途 |
|---|---|---|
| `test-image.jpeg` | `mlops-cloud/e2e/fixtures/test-image.jpeg` | Phase1 image upload |
| `test-video.mp4` | `mlops-cloud/e2e/fixtures/test-video.mp4` | Phase1 inference seed / Phase4 GPU pipeline |

元ファイル:

- `/home/taiga/mlops-cloud-dev/test-image.jpeg`
- `/home/taiga/mlops-cloud-dev/test-video.mp4`

## 10. 失敗時の確認ポイント

compose service 状態:

```bash
docker compose -f e2e/compose.phaseX.yml ps
```

ログ:

```bash
docker compose -f e2e/compose.phaseX.yml logs --tail=200
```

特定 service のログ:

```bash
docker compose -f e2e/compose.phase4.yml logs --tail=300 mlx-backend cv-backend phase4-test
```

SurrealDB を直接確認:

```bash
docker compose -f e2e/compose.phase4.yml exec -T database /surreal sql \
  --endpoint http://127.0.0.1:8000 \
  --username root \
  --password root \
  --namespace mlops_phase4 \
  --database cloud_gpu \
  --pretty <<'SQL'
SELECT id,status,progress FROM inference_job;
SELECT id,key,meta FROM inference_result;
SELECT id,status,file FROM hls_job;
SQL
```

よくある原因:

| 症状 | 確認点 |
|---|---|
| `/api/status` が落ちる | `cloud-ui` env、SurrealDB/MinIO 起動、bucket 作成 |
| upload 後に S3 object が見つからない | `MINIO_BUCKET` と DB の `bucket/key` が一致しているか |
| Phase2 import error | pytest 実行コンテナで `/app` が `sys.path` に入っているか |
| Phase4 が進まない | `mlx-backend` log、`inference_job.progress.current_key` |
| Phase4 GPU error | `docker run --rm --gpus all ... nvidia-smi`、NVIDIA runtime、driver/container CUDA compatibility |
| HLS ができない | `cv-backend` log、`hls_job.status`、`hls_playlist` / `hls_segment` |

## 11. CI への載せ方の目安

PR 必須候補:

```bash
docker compose -f e2e/compose.phase1.yml up --build --abort-on-container-exit --exit-code-from e2e e2e
docker compose -f e2e/compose.phase2.yml up --build --abort-on-container-exit --exit-code-from backend-test backend-test
```

main / nightly 候補:

```bash
docker compose -f e2e/compose.phase3.yml up --build --abort-on-container-exit --exit-code-from system-e2e system-e2e
```

manual / nightly GPU 候補:

```bash
docker compose -f e2e/compose.phase4.yml up --build --abort-on-container-exit --exit-code-from phase4-test phase4-test
```

CI では必ず最後に `down -v` を実行してください。

## 12. 現在の注意事項

- Phase1 には `test.fixme` の skip があります。これはテスト自体が不要なのではなく、仕様/実装が未確定の箇所を明示するためのものです。
- Phase2/3/4 は現時点で skip なしです。
- Phase4 は実モデルを動かすため、ネットワーク download、GPU runtime、checkpoint/cache、Ultralytics/TensorRT の状態に影響されます。
- `mlops-cloud-ui/next-env.d.ts` は Next.js build/dev により自動更新されることがあります。
- E2E compose はデータ永続化を目的にしていません。DB/S3 は毎回リセットされる前提です。
