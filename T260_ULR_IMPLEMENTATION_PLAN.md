# T260-ULR Implementation Plan

作成日: 2026-04-29

## 調査結果

- 現行 `samurai-ulr` は `mlops-cloud-backend/ml_module/model_samurai_ulr.py` が中心です。
  - SAM2 tracking
  - SAM2結果からYOLO形式疑似データセット生成
  - Ultralytics RT-DETR学習
  - RT-DETR / TensorRT推論
  - HLS化は既存 `video_manager.py` に委譲
- Docker環境は `uv sync --extra=mlx` ですが、SAM2本体は `uv` 管理ではなく `Dockerfile.gpu` で `moriyalab/samurai` を clone しています。
- UIは `/inference/create` で `SAMURAI ULR (internet)` のみ選択可能です。E2E Phase1/Phase4 も `model: "samurai-ulr"` 前提です。
- 公式SAM2は Python `>=3.10`, Torch `>=2.5.1`, torchvision `>=0.20.1` が前提で、現在の backend `torch==2.8.0+cu128` と整合します。
  - Source: https://github.com/facebookresearch/sam2
- RF-DETR は 2026-04-29 時点で PyPI 最新が `rfdetr==1.6.5`、Python `>=3.10` 対応です。学習には `rfdetr[train]`、ONNX/TensorRT系には `rfdetr[onnx]` / `rfdetr[trt]` が関係します。
  - Source: https://pypi.org/project/rfdetr/
  - Source: https://github.com/roboflow/rf-detr
  - Source: https://rfdetr.roboflow.com/latest/

## 方針

T260-ULR は既存 `samurai-ulr` を置換せず、新しい `model: "t260-ulr"` として追加します。

理由:

- 既存E2Eと互換性を壊さない。
- `samurai-ulr` と `t260-ulr` の比較検証ができる。
- Phase4 GPU E2Eで段階的に切り替えられる。

## 目標アーキテクチャ

```text
inference_job
  taskType: one-shot-object-detection
  modelSource: internet
  model: t260-ulr
        |
        v
T260-ULR backend adapter
        |
        +-- SAM2.1 video tracking
        |     seed: annotation.category = sam2_key_bbox
        |     output: masks / bbox parquet
        |
        +-- RF-DETR training
        |     input: SAM2.1 pseudo labels
        |     output: checkpoint_best_total.pth
        |
        +-- RF-DETR inference
        |     input: original video
        |     output: parquet + plotted mp4
        |
        +-- existing upload / inference_result / HLS flow
```

## 実装ステップ

### 1. Docker / uv dependency 整備

対象: `mlops-cloud-backend`

- `pyproject.toml` の `mlx` extra に追加:
  - `rfdetr[train,onnx]==1.6.5`
  - `sam-2 @ git+https://github.com/facebookresearch/sam2.git`
- `uv lock` を更新。
- `Dockerfile.gpu` から Python import 用の `moriyalab/samurai` 依存を外す。
- SAM2.1 checkpoint / config は公式 `facebookresearch/sam2` に寄せる。
- まず TensorRT は既存 RT-DETR 経路と分け、T260初期版は `pytorch-fp16` / `pytorch-fp32` を優先する。
- TensorRTはRF-DETRのONNX export確認後に `tensorrt-fp16` として有効化する。

### 2. CLI単位で動作確認

新規または置換候補:

- `ml_module/cli_infer_sam2_1.py`
  - official SAM2.1 predictor を使う。
  - 複数 seed bbox を1回の video state で処理する。
  - parquet出力形式は既存に合わせる。
- `ml_module/cli_train_rfdetr.py`
  - RF-DETR用 dataset layout を生成・検証する。
  - `RFDETRMedium` または `RFDETRLarge` を env で選択可能にする。
  - E2E既定は軽め、実運用既定は精度優先にする。
- `ml_module/cli_infer_rfdetr.py`
  - fine-tuned checkpoint を読み込む。
  - frameごとに `model.predict(...)`。
  - parquet + overlay mp4 を出す。

### 3. Backend adapter追加

- `ml_module/model_t260_ulr.py` を追加。
- `ml_module/registry.py` に `t260-ulr` を登録。
- 既存 `SamuraiULRModel` は残す。
- progress step は初期は既存キーを流用:
  - `download`
  - `preprocess`
  - `sam2`
  - `dataset_export`
  - `rtdetr_train` は後で表示名だけ `RF-DETR train` に変更候補
  - `rtdetr_infer` は後で `RF-DETR inference` に変更候補
  - `aggregate`
  - `postprocess`
  - `upload`

### 4. UI選択肢追加

対象: `mlops-cloud-ui/app/inference/create/page.tsx`

- Internet Model に追加:
  - `T260 ULR (SAM2.1 + RF-DETR)`
  - value: `t260-ulr`
- `samurai-ulr` と同じ one-shot object detection 要件を表示。
- 初期実装では既存 `inferenceBackend` / `rtdetrEpochs` を再利用。
- 既定 backend は T260 では `pytorch-fp16` にする案が安全。TensorRTは後段で有効化。

### 5. E2E追加

対象: `mlops-cloud`

- Phase1:
  - UIで `T260 ULR` を選択できること。
  - 作成された `inference_job.model` が `t260-ulr` になること。
- Phase2:
  - `t260-ulr` が registry で unsupported 扱いにならないこと。
  - 既存の invalid job tests を壊さないこと。
- Phase4:
  - `test_real_t260_ulr_gpu_pipeline_to_hls_and_ui` を追加。
  - 最初は `PHASE4_MODEL=t260-ulr` のように切り替え可能にし、GPU時間を倍増させない構成にする。
  - 成果物検証は既存と同じ:
    - `inference_job.status == Completed`
    - `plot_video`
    - `results_parquet`
    - HLS playlist / segment
    - inference UI 200

### 6. 検証順序

承認後は次の順で進めます。

1. `cd mlops-cloud-backend && uv sync --extra=mlx`
2. GPU Docker image build
3. Docker内 import smoke:
   - `import sam2`
   - `import rfdetr`
   - `import torch`
4. SAM2.1 CLI smoke
5. RF-DETR train CLI smoke
6. RF-DETR inference CLI smoke
7. backend registry / runner の局所テスト
8. UI type-check / lint
9. Phase1 E2E
10. Phase2 E2E
11. Phase4 GPU E2E

## リスク

- RF-DETR のYOLO dataset layout は現行 exporter と違う可能性が高いため、T260専用 exporter を作る。
- RF-DETR TensorRT は `trtexec` やONNX export条件に依存するため、初期実装では PyTorch FP16/FP32 完走を優先する。
- SAM2 CUDA extension は `nvcc` がない環境でビルド警告が出る可能性がある。必要なら `SAM2_BUILD_CUDA=0` でまず安定化し、性能検証時にCUDA devel imageへ寄せる。
- Phase4はGPU・ネットワーク・checkpoint downloadに依存するため、失敗時はログを保存して段階ごとに切り分ける。

## 承認後の最初の作業

まず `mlops-cloud-backend` の dependency / Docker を `uv sync --extra=mlx` で再現可能にし、SAM2.1 と RF-DETR の import smoke まで進めます。その後、CLI単体、backend統合、UI、E2Eの順で実装します。
