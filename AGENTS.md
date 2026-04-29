# AGENTS.md

このファイルは、AI エージェントや開発支援ツールがこのワークスペースで作業するときのガイドです。作業前に [ARCHITECTURE.md](./ARCHITECTURE.md) を読み、実装の責務境界を確認してください。

## ワークスペースの位置づけ

ここは単一アプリの通常リポジトリではなく、MLOps Cloud を構成する4つのリポジトリを同じ階層に置いた開発支援ワークスペースです。

| パス | 責務 |
|---|---|
| `mlops-cloud/` | 統合 compose、E2E、リリース単位のデプロイ入口。 |
| `mlops-cloud-ui/` | Next.js UI、API routes、DB/S3 プロキシ。 |
| `mlops-cloud-backend/` | Python ワーカー群、共通 DB/S3 wrapper、ML/動画処理。 |
| `mlops-cloud-updater/` | latest release 監視と compose 更新補助。 |

## 最初に確認するファイル

- 全体設計: `ARCHITECTURE.md`
- レビュー課題: `REVIEW_FINDINGS.md`
- E2E 手順: `E2E_TEST_RUNBOOK.md`
- 統合開発 compose: `mlops-cloud/docker-compose.dev.yml`
- 本番寄り compose: `mlops-cloud/docker-compose.yml`
- UI package: `mlops-cloud-ui/package.json`
- Backend package: `mlops-cloud-backend/pyproject.toml`

## アーキテクチャ上の前提

- UI と backend は直接 REST/RPC で会話しません。SurrealDB と MinIO/S3 が共有境界です。
- UI は Next.js API routes 経由で SurrealDB/S3 にアクセスします。ブラウザから DB/S3 へ直接つなぐ前提に戻さないでください。
- Backend は単一 API サーバーではなく、DB をポーリングする常駐ワーカー群です。
- `mlops-cloud` はオーケストレーション用で、アプリ本体のコードは基本的に `mlops-cloud-ui` と `mlops-cloud-backend` にあります。
- `mlops-cloud-updater` は `mlops-cloud` の GitHub Release を更新単位として扱います。

## 実装時の注意

- `Faild` と `StopInterrept` は既存状態値として使われています。綴りだけを理由に一括変更しないでください。
- 推論 backend は現状、`taskType=one-shot-object-detection`, `modelSource=internet`, `model=samurai-ulr`、かつ単一データセット・単一動画を前提にします。
- 推論作成 UI では backend を `TensorRT FP16`, `PyTorch FP16`, `PyTorch FP32` から選べます。互換性のため既定値は TensorRT FP16 です。
- RT-DETR 学習 epoch は UI から可変ですが、既定値は 4 です。
- 推論成果物の動画は mp4 key でも HLS 化済みとして扱います。UI の動画再生は `hls_playlist` と `/api/storage/hls/playlist` を使う前提です。
- `training_job` は UI 中心の機能で、常駐 training worker は未確認です。Training を実行済み機能として扱う変更は避け、仕様を明示してください。
- HLS 生成後に `video_manager.py` が元 `file.key` を再パック MP4 に差し替える設計があります。元ファイル保持や監査に関わる変更では副作用を確認してください。
- Cleaner は `dead=true` や orphan record を非同期削除します。UI の削除操作は多くの場合ソフト削除です。
- `/api/db/query` は raw SQL プロキシとして扱わず、allowlist operation と入力検証を前提にしてください。新規外部公開機能では専用 API route を優先してください。
- Webターミナル機能は削除済みです。ホストSSHやシェル操作をUIから再導入しないでください。

## よく使うコマンド

統合開発環境:

```bash
cd mlops-cloud
docker compose -f docker-compose.dev.yml up --build
```

GPU ワーカー込み:

```bash
cd mlops-cloud
docker compose -f docker-compose.dev.yml --profile gpu up --build
```

UI 検証:

```bash
cd mlops-cloud-ui
npm ci
npm run type-check
npm run lint
npm run build
```

Backend 依存同期:

```bash
cd mlops-cloud-backend
uv sync
```

E2E:

```bash
cd mlops-cloud
docker compose -f e2e/compose.phase1.yml up --build --abort-on-container-exit --exit-code-from e2e e2e
docker compose -f e2e/compose.phase2.yml up --build --abort-on-container-exit --exit-code-from backend-test backend-test
docker compose -f e2e/compose.phase3.yml up --build --abort-on-container-exit --exit-code-from system-e2e system-e2e
```

各 E2E 実行後は対象 compose を `down -v` で片付けてください。

## コーディング方針

- 既存の局所パターンを優先してください。大きな抽象化や横断リファクタは、必要性が明確な場合だけ行ってください。
- UI は Next.js App Router、React 19、Chakra UI、React Query の構成です。`@/*` alias を使えます。
- UI では npm と `package-lock.json` を基準にしてください。
- Backend は Python 3.11 と uv を基準にしてください。
- DB/S3 接続設定は `SURREAL_*` と `MINIO_*` を優先してください。旧 `S3_*` / `SURREAL_ENDPOINT` 系は互換 fallback として扱います。
- Dockerfile 名は現在 `Dockerfile.base` と `Dockerfile.gpu` です。古い `Dockerfile.cv` / `Dockerfile.mlx` 参照を増やさないでください。

## 検証方針

- UI 変更では最低限 `npm run type-check` と `npm run lint` を検討し、画面や route handler に影響する場合は `npm run build` まで確認してください。
- UI の局所変更では `npx eslint <changed-file>` も使ってください。全体 lint は既存設定問題に当たる場合があります。
- Backend の共通処理、query helper、Cleaner、inference 入力制約を変える場合は Phase 2 E2E を優先してください。
- UI と DB/S3 の連携を変える場合は Phase 1 または Phase 3 E2E を実行してください。
- 実推論、SAMURAI、RT-DETR、HLS 結果確認に関わる変更は Phase 4 が最も近い検証です。ただし GPU 環境前提のため、実行できない場合はその理由を明記してください。
- 2026-04-29 時点の Phase 1 期待値は `7 passed, 3 skipped` です。skip は未確定仕様の `test.fixme` です。

## Git / PR 運用

- main へ直接 commit / push しないでください。
- 各下位リポジトリで作業する場合は、そのリポジトリ内で `codex/<description>` ブランチを切って commit / push します。
- PR は変更したリポジトリ単位で分けてください。
- PR 本文には実施した validation と E2E 結果を具体的に書いてください。

## ドキュメント更新

アーキテクチャ、状態値、DB テーブル、compose サービス、環境変数、E2E 手順を変えた場合は、該当するドキュメントも更新してください。

- 設計変更: `ARCHITECTURE.md`
- 開発入口やコマンド変更: `README.md`
- エージェント向け作業ルール変更: `AGENTS.md`
- テスト手順変更: `E2E_TEST_RUNBOOK.md`
- 既知課題の解消や追加: `REVIEW_FINDINGS.md`
