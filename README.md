# MLOps Cloud Development Workspace

このリポジトリは、MLOps Cloud を構成する複数リポジトリを同じワークスペースで開発・検証するための開発支援リポジトリです。

詳細な設計は [ARCHITECTURE.md](./ARCHITECTURE.md) にまとめています。この README では、構成の見取り図、開発時の入口、よく使うコマンドを整理します。

## 構成

| パス | 役割 |
|---|---|
| `mlops-cloud/` | 統合 Docker Compose、E2E テスト、デプロイ入口。 |
| `mlops-cloud-ui/` | Next.js UI と API routes。ブラウザ操作、DB/S3 プロキシ、データセット・推論・学習画面を担当。 |
| `mlops-cloud-backend/` | Python ワーカー群。動画処理、推論、メトリクス、クリーンアップを担当。 |
| `mlops-cloud-updater/` | リリース監視とホスト上の compose 更新を行う補助サービス。 |
| `ARCHITECTURE.md` | ワークスペース全体の設計、データモデル、主要フロー、運用上の注意。 |
| `E2E_TEST_RUNBOOK.md` | E2E テストの実行手順。 |
| `REVIEW_FINDINGS.md` | 現状レビューで見つかった課題と優先度。 |
| `clone-repository.sh` | 必要な4リポジトリをまとめて clone する補助スクリプト。 |

## アーキテクチャ概要

MLOps Cloud は、UI と複数バックエンドワーカーが SurrealDB と MinIO/S3 を共有する非同期ジョブ型アーキテクチャです。

- UI は Next.js アプリです。ブラウザ操作を受け、Next.js API routes 経由で SurrealDB と MinIO/S3 にアクセスします。
- バックエンドは単一 API サーバーではなく、DB をポーリングする常駐ワーカー群です。
- UI とバックエンドは直接 HTTP API で会話せず、SurrealDB のレコードと S3 オブジェクトを介して連携します。
- `mlops-cloud/` の compose が UI、DB、MinIO、各ワーカーを束ねます。

主な共有状態は `file`, `hls_job`, `hls_playlist`, `hls_segment`, `inference_job`, `inference_result`, `training_job`, `hardware_metric` です。

## 初期セットアップ

既に下位リポジトリが存在する場合は不要です。新しい作業ディレクトリで揃える場合は次を実行します。

```bash
./clone-repository.sh
```

特定 owner や branch を使う場合:

```bash
./clone-repository.sh --owner takanotaiga --branch main
```

## 統合開発環境

通常の開発は `mlops-cloud/docker-compose.dev.yml` を使います。UI と backend のローカルソースをコンテナへ mount し、SurrealDB は memory、MinIO は tmpfs で起動します。DB/S3 の状態は起動ごとにリセットされます。

```bash
cd mlops-cloud
docker compose -f docker-compose.dev.yml up --build
```

GPU ワーカーも起動する場合:

```bash
cd mlops-cloud
docker compose -f docker-compose.dev.yml --profile gpu up --build
```

停止:

```bash
cd mlops-cloud
docker compose -f docker-compose.dev.yml down
```

主な URL:

| URL | 用途 |
|---|---|
| http://localhost:3000 | MLOps Cloud UI |
| http://localhost:9001 | MinIO Console |
| http://localhost:8000 | SurrealDB |

開発 compose のデフォルト資格情報:

| 対象 | 値 |
|---|---|
| SurrealDB user/pass | `root` / `root` |
| SurrealDB namespace/database | `mlops` / `cloud_ui` |
| MinIO user/pass | `minioadmin` / `minioadmin` |
| MinIO bucket | `mlops-datasets` |

## 個別開発

### UI

```bash
cd mlops-cloud-ui
npm ci
npm run dev
```

検証:

```bash
cd mlops-cloud-ui
npm run type-check
npm run lint
npm run build
```

UI は npm / `package-lock.json` を基準にしてください。Dockerfile も npm を使います。

### Backend

```bash
cd mlops-cloud-backend
uv sync
```

軽量ワーカーの例:

```bash
uv run hardware_metrics_manager.py
uv run cleaner_manager.py
```

動画処理・推論系は Dockerfile と compose 経由の実行を優先してください。GPU 依存、FFmpeg、SAMURAI/SAM2/RT-DETR などの前提が重いためです。

### 統合 compose

本番寄りの compose は公開 image を使います。

```bash
cd mlops-cloud
docker compose up -d
```

ローカルソースを反映した開発では `docker-compose.dev.yml` を使ってください。

## テスト

E2E は `mlops-cloud/e2e/` に集約されています。詳しくは [E2E_TEST_RUNBOOK.md](./E2E_TEST_RUNBOOK.md) を参照してください。

Phase 1: UI E2E

```bash
cd mlops-cloud
docker compose -f e2e/compose.phase1.yml up --build --abort-on-container-exit --exit-code-from e2e e2e
docker compose -f e2e/compose.phase1.yml down -v
```

Phase 2: Backend integration

```bash
cd mlops-cloud
docker compose -f e2e/compose.phase2.yml up --build --abort-on-container-exit --exit-code-from backend-test backend-test
docker compose -f e2e/compose.phase2.yml down -v
```

Phase 3: System smoke

```bash
cd mlops-cloud
docker compose -f e2e/compose.phase3.yml up --build --abort-on-container-exit --exit-code-from system-e2e system-e2e
docker compose -f e2e/compose.phase3.yml down -v
```

Phase 4: GPU E2E

```bash
cd mlops-cloud
docker compose -f e2e/compose.phase4.yml up --build --abort-on-container-exit --exit-code-from phase4-test phase4-test
docker compose -f e2e/compose.phase4.yml down -v
```

Phase 4 は NVIDIA container runtime と十分な GPU リソースが必要です。

## 開発時の重要な注意

- `/api/db/query` は raw SQL プロキシとして扱わず、allowlist operation と入力検証を前提にしてください。新規機能では専用 API route を優先します。
- Webターミナル機能は削除済みです。ホストSSHやシェル操作をUIから再導入しないでください。
- `Faild` や `StopInterrept` は綴りが不自然ですが、既存 DB 値・UI・backend の契約として扱われています。変更する場合は互換マッピングを用意してください。
- 推論 backend は現状、単一データセットかつ単一動画を前提にしています。UI 変更時はこの制約を破らないようにしてください。
- 推論 UI は backend を `TensorRT FP16`, `PyTorch FP16`, `PyTorch FP32` から選べます。既定値は互換性のため `TensorRT FP16` です。
- RT-DETR 学習 epoch は UI から指定でき、既定値は 4 です。
- 推論成果物動画は HLS 化済みとして扱います。mp4 artifact でも再生は `hls_playlist` と `/api/storage/hls/playlist` 経由です。
- `training_job` は UI で作成できますが、このワークスペース内では常駐 training worker が未接続です。
- 下位リポジトリの README/AGENTS も現在の構成に合わせています。迷った場合は `ARCHITECTURE.md`、実ファイル、E2E compose を優先してください。

## PR / 検証運用

- main へ直接 commit / push しないでください。
- 作業は変更対象リポジトリで `codex/<description>` ブランチを切って行います。
- PR はリポジトリごとに分け、validation と E2E 結果を本文に書いてください。
- UI と DB/S3 の連携を変えた場合は Phase 1 E2E を優先します。
- 2026-04-29 時点の Phase 1 E2E 期待値は `7 passed, 3 skipped` です。

## 参考ドキュメント

- [ARCHITECTURE.md](./ARCHITECTURE.md): 全体設計、データモデル、主要フロー。
- [E2E_TEST_PLAN.md](./E2E_TEST_PLAN.md): E2E テスト導入計画。
- [E2E_TEST_RUNBOOK.md](./E2E_TEST_RUNBOOK.md): E2E 実行手順。
- [REVIEW_FINDINGS.md](./REVIEW_FINDINGS.md): 優先度つきレビュー課題。
- [SurrealDBv3.md](./SurrealDBv3.md): SurrealDB v3 関連メモ。
