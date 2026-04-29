# MLOps Cloud レビュー課題

作成日: 2026-04-28  
対象ワークスペース: `/Users/taiga/Desktop/mlops_cloud_ws`

このドキュメントは、現状レビューで見つかった主要課題を、修正方針と優先度つきで整理したものです。E2Eテスト計画は別ファイル `E2E_TEST_PLAN.md` に分離しています。

## 総評

現状のMLOps Cloudは、UI、SurrealDB、MinIO/S3、非同期バックエンドワーカーを分離した構成になっており、MVPとしての骨格は成立しています。特に、UIがジョブやメタデータをDBに書き、バックエンドがDBをポーリングして成果物をS3へ戻す設計は、機能追加しやすい構造です。

一方で、本番MLOpsとして見ると、セキュリティ境界、UIとバックエンドの契約、ジョブ状態管理、Training実行系、運用設定、テスト基盤が不足しています。まずは安全性と契約を固め、そのうえで機能拡張するのが妥当です。

## P0: 任意SQLプロキシが強すぎる

対象:

- `mlops-cloud-ui/app/api/db/query/route.ts:8-16`

現状:

`POST /api/db/query` が、ブラウザから渡されたSQL文字列をサーバー側SurrealDB資格情報でそのまま実行しています。

リスク:

- UI利用者が任意の `SELECT` / `UPDATE` / `DELETE` / `CREATE` を実行できる。
- ブラウザ側のバグやXSSが、そのままDB全権限操作に発展する。
- テーブル単位・レコード単位の認可を実装できない。
- APIの外部公開時に最も危険な入口になる。

短期対応:

- `/api/db/query` を外部公開しない前提で、少なくとも認証済みユーザーだけに制限する。
- SQL文字列を受ける汎用APIを段階的に廃止する。
- まず高頻度導線から専用APIへ置き換える。
  - dataset list
  - file create/update/delete
  - inference job create/list/detail
  - annotation/label operations
  - hardware metrics read

中期対応:

- API routeを用途別に分割し、入力schemaを検証する。
- mutation系は操作ごとの権限チェックを入れる。
- DB操作はサーバー側repository/service層に閉じ込める。
- クエリ監査ログを残す。

完了条件:

- ブラウザから任意SQLを送れない。
- UI主要導線が専用APIで動く。
- mutation APIに入力validationと認可がある。
- E2Eで「許可されないDB操作が拒否される」ことを確認できる。

## P0: Webターミナルが本番境界として危険（解消済み）

対象:

- `mlops-cloud-backend/terminal_manager.py`（削除済み）
- `mlops-cloud/docker-compose.yml` / `docker-compose.dev.yml` の `terminal-manager` service（削除済み）
- `mlops-cloud-ui/app/terminal` / `components/terminal`（削除済み）

対応:

- WebSocket terminal bridge と UI route を削除した。
- 本番/開発 compose から `terminal-manager` service と `8765` 公開を削除した。
- backend の terminal protocol doc と実装ファイルを削除した。

残リスク:

- 同等機能を再導入する場合は、別途認証/認可、監査ログ、接続先制限、短命トークン、ネットワーク境界を設計してから実装する。

完了条件:

- 本番/開発標準構成でWebターミナルのUI、WebSocket service、ホスト公開ポートが存在しない。
- E2Eで `/terminal` と `8765` のWebSocket到達経路が存在しないことを確認できる。

## P1: UIと推論バックエンドの制約が不一致

対象:

- UI: `mlops-cloud-ui/app/inference/create/page.tsx`
- Backend: `mlops-cloud-backend/ml_inference_manager.py:69-92`

現状:

UIは複数データセットを選択できる一方、バックエンドは以下を要求します。

- `inference_job.datasets` は配列。
- データセット数は1つだけ。
- 対象データセット内の動画は1本だけ。

リスク:

- 通常のUI操作で失敗するジョブを作れる。
- ユーザーが何を直せばよいか分からない。
- `ProcessWaiting` から `Faild` になるだけで、原因表示が弱い。

短期対応:

- UI側で推論ジョブは単一データセット選択に制限する。
- 対象データセット内の動画数を事前チェックする。
- 複数動画/動画なしの場合はStartボタンを無効化し、理由を表示する。

中期対応:

- バックエンドが複数データセット/複数動画を処理できるようにするか、仕様として単一入力に固定する。
- `inference_job` に `errorMessage` / `failureReason` を保存する。
- 失敗時にUI詳細画面で原因を表示する。

完了条件:

- UIからバックエンド非対応の推論ジョブを作れない。
- バックエンド側でも不正ジョブに分かりやすい失敗理由を残す。
- E2Eで複数データセット選択が防がれることを確認できる。

## P1: Trainingジョブは作れるが実行系が未接続

対象:

- `mlops-cloud-ui/app/training/create/page.tsx:171-200`
- `mlops-cloud-ui/components/training/training-jobs-page.tsx`
- `mlops-cloud-ui/app/training/opened-job/client.tsx`

現状:

UIは `training_job` を作成/更新できますが、このワークスペース内には `training_job` をポーリングして実行する常駐workerが見当たりません。

リスク:

- ユーザーから見ると「開始できるが進まない」機能になる。
- MLOpsの中核である学習・評価・モデル登録の流れが未完了に見える。
- 完了済みTraining jobを推論のmodel sourceとして選ぶUIがあるため、Training未接続の影響が推論導線にも波及する。

短期対応:

- Training機能を明示的にpreview/disabled扱いにする。
- worker未接続ならStartを無効化する。
- もしくはUIからTraining導線を一時的に隠す。

中期対応:

- `training_manager.py` を追加し、`training_job` を処理する。
- Training成果物をS3へ保存し、DBに `model_artifact` または `training_result` を記録する。
- 推論側の `modelSource = trained` と接続する。
- 学習ログ、評価指標、モデルバージョン、再現用設定を保存する。

完了条件:

- Trainingを開始したら状態が進む。
- 成果物が登録され、推論で選べる。
- 未対応の場合はUIから開始できない。
- E2EでTraining導線の現在仕様が検証されている。

## P1: デフォルト資格情報と公開ポートがそのまま

対象:

- `mlops-cloud/docker-compose.yml:4-59`

現状:

SurrealDBとMinIOがデフォルト系の資格情報で起動し、DB/S3ポートがホストへ公開されています。

リスク:

- 閉域外に出た場合、DB/S3へ直接アクセスされる。
- composeファイルに資格情報が固定値として残る。
- 環境ごとのsecret rotationが困難。

短期対応:

- `.env` / secret managerから資格情報を注入する。
- 本番composeではDB/S3ポートをホスト公開しない。
- UI/backendだけが内部ネットワークでDB/S3へ到達する構成にする。

中期対応:

- dev composeとprod composeを分ける。
- reverse proxy/TLS/認証を明示する。
- MinIO bucket policyを最小権限化する。
- SurrealDBユーザー/権限を用途別に分ける。

完了条件:

- 本番用composeに固定デフォルト資格情報がない。
- DB/S3は原則内部ネットワークのみ。
- E2Eでアプリ経由のアクセスは通り、直接アクセスは不要な構成になっている。

## P1: ジョブ状態値と失敗表現が不統一

対象:

- `mlops-cloud-backend/query/ml_inference_job_query.py`
- `mlops-cloud-ui/app/inference/opened-job/client.tsx`
- `mlops-cloud-ui/components/inference/inference-jobs-page.tsx`
- `mlops-cloud-ui/app/training/opened-job/client.tsx`

現状:

`Faild`、`Failed`、`Complete`、`Completed`、`StopInterrept` など、複数の状態表現が混在しています。

リスク:

- UI表示条件とworker遷移条件がずれる。
- 終了判定、再実行判定、Cleaner対象判定が壊れやすい。
- 新しいworker追加時に互換性問題が起きる。

短期対応:

- 現在使われている状態値を一覧化する。
- UI側にnormalize関数を集中させる。
- 失敗理由は `status` ではなく別フィールドへ出す。

中期対応:

- 標準状態を定義する。
  - `queued`
  - `running`
  - `completed`
  - `failed`
  - `cancel_requested`
  - `cancelled`
- 既存値はmigrationまたは互換マッピングで吸収する。

完了条件:

- 状態値の仕様書がある。
- UI/worker/Cleanerが同じ状態定義を使う。
- 状態遷移テストがある。

## P2: HLS再パックで元ファイルが差し替わる

対象:

- `mlops-cloud-backend/video_manager.py`

現状:

HLS生成後、元の `file.key` を再パックMP4へ差し替え、元オブジェクトを削除します。

リスク:

- 元アップロードファイルが保持されない。
- 監査や再現性の観点で、元ファイルと加工後ファイルの境界が曖昧。
- S3 keyが変わるため、外部参照がある場合に壊れる。

短期対応:

- `meta.repackedFrom` をUI/ドキュメントで明示する。
- 元ファイル削除を設定で無効化できるようにする。

中期対応:

- `file_variant` または `asset` テーブルを導入し、original / hls / repacked / thumbnailを別variantとして扱う。
- 元ファイル保持ポリシーを設定化する。

完了条件:

- originalとderived artifactの関係がDBで追跡できる。
- 元ファイル保持/削除ポリシーが明示されている。

## P2: READMEと実装の差分

対象:

- `mlops-cloud-backend/README.md`
- `mlops-cloud-ui/README.md`

現状:

実装とREADMEの一部に差分があります。

- backend READMEは `Dockerfile.cv` / `Dockerfile.mlx` に言及するが、実ファイルは `Dockerfile.base` / `Dockerfile.gpu`。
- UI READMEはYarn中心だが、Dockerfile/lockfile/CIはnpm中心。

リスク:

- 新規開発者が誤った手順で環境構築する。
- CI/CDや運用手順とローカル手順がずれる。

対応:

- READMEを現行実装に合わせる。
- dev/prod/CIの起動手順を分けて書く。
- Architecture文書からリンクする。

完了条件:

- README通りに起動/ビルド/テストできる。
- Dockerfile名、パッケージマネージャ、環境変数が一致している。

## 推奨対応順

1. `/api/db/query` の制限または専用API化。
2. 推論作成UIをバックエンド制約に合わせる。
3. Training導線をdisabled/preview化、またはworker実装を開始。
4. composeのsecret化とDB/S3内部ネットワーク化。
5. 状態値のnormalizeと仕様化。
6. HLS/派生成果物のデータモデル整理。
7. README更新。

## 受け入れ基準

上記課題を解消する変更には、最低限以下のテストが必要です。

- 認可されないDB操作が拒否される。
- 推論作成UIが非対応入力を防ぐ。
- Training未接続時に開始できない、またはworker接続時に状態が進む。
- 本番compose相当でDB/S3がアプリ経由で使える。
- WebターミナルのUI/WS接続が標準構成に存在しない。

具体的なE2Eテスト計画は `E2E_TEST_PLAN.md` を参照してください。
