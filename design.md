# Immich → S3 バックアップ設計書

## 1. 目的とゴール

ローカルサーバーで運用している Immich のデータを、災害復旧目的で S3 Glacier Deep Archive に定常的にバックアップする。

- 平常時に取り出す予定はなく、HDD が故障した場合のみリストアする想定（取り出しコストが高額なため）
- ローカルサーバーがダウンしている期間も含め、バックアップが正常に走っていることを Slack で常時把握できる
- 運用コストを最小化（後述：実質月額 数ドル以下）

---

## 2. 現状システム構成

| 項目 | 値 |
|---|---|
| OS | Ubuntu 24.04.4 LTS |
| `UPLOAD_LOCATION` | `/mnt/hdd1`（外付け HDD 2TB、現在 500GB 使用） |
| `DB_DATA_LOCATION` | `./postgres`（内蔵 SSD 256GB） |
| Immich 稼働形態 | Docker Compose |

---

## 3. バックアップ対象

### 3.1 含めるもの

#### メディアデータ（オリジナルが格納される 3 ディレクトリのみ）
- `UPLOAD_LOCATION/library/` — Storage Template 有効時のオリジナル写真・動画
- `UPLOAD_LOCATION/upload/` — Web/モバイル/CLI からアップロードされたオリジナル
- `UPLOAD_LOCATION/profile/` — ユーザーアバター

#### PostgreSQL データベース
- コンテナ内で `pg_dumpall`（または `pg_dump`）を実行した論理バックアップ（SQL ダンプ）

#### 設定ファイル
- `docker-compose.yml`
- `.env`
- その他プロビジョニング関連ファイル

### 3.2 除外するもの（再生成可能のため）

| パス | 理由 |
|---|---|
| `UPLOAD_LOCATION/thumbs/` | サムネイル・プレビュー → リストア後に Immich のジョブで再生成 |
| `UPLOAD_LOCATION/encoded-video/` | 再エンコード動画 → リストア後にジョブで再生成 |
| `UPLOAD_LOCATION/backups/` | Immich 自身が出力する DB ダンプ。自前で `pg_dumpall` するため重複 |

`tar` 実行時は `--exclude='./thumbs' --exclude='./encoded-video' --exclude='./backups'` を付与する。

これにより S3 の保管容量・PUT 回数・転送時間がいずれも削減される。リストア後はサムネ生成・トランスコードジョブを再走させる必要があるが、オリジナルは無傷なのでデータ損失はない。

---

## 4. バックアップ戦略

### 4.1 フル / 差分の方針

| 種別 | 頻度 | 内容 |
|---|---|---|
| フル | 毎年 1/1 と 7/1 の年 2 回 | 「3.1 含めるもの」全て |
| 差分 | 毎週（曜日要決定） | メディアデータの増分のみ + DB のフル論理ダンプ |

### 4.2 スケジュール

- **フル**: `cron` で `0 3 1 1,7 *`（1/1 および 7/1 の 03:00）
- **差分**: `cron` で毎週 1 回（例：日曜 03:00）
- いずれもサーバーローカルタイム

### 4.3 保管ポリシー

#### フル
- 削除ポリシーは設けない
- **次回フルバックアップが正式に完了 + 10 日経過した時点で**、前回フルを削除コマンドで削除
  - 10 日のバッファ理由：
    - Glacier Deep Archive の最低保存期間 180 日（早期削除すると残日数分の保存料金が課金される）
    - 1/1 → 7/1 = 181 日と境界ぎりぎりのため、バックアップ開始時刻のズレ・処理遅延等で 180 日を割らないよう余裕を持たせる
  - スクリプトは旧フルのアップロード日付を S3 オブジェクトのメタデータか命名規則から判定し、`(now - upload_date) >= 190 日` を確認してから削除

#### 差分
- ライフサイクルルールで **180 日経過後に自動削除**

### 4.4 差分バックアップの仕組み（メディア）

`tar --listed-incremental=<snapshot-file>` を使用して、前回バックアップ以降に変更されたファイルのみを tar に含める。

- スナップショットファイル（例: `/mnt/hdd1/.backup_state/snapshot.snar`）はローカルに保持する
- このファイルが破損 / 失われると、次回の「差分」が事実上のフルになる（tar の挙動上、復元自体は壊れない）
- スナップショットファイル自体も毎日ローカルでコピー保管しておく（例: `cp snapshot.snar snapshot.snar.bak`）
- フル取得時はスナップショットファイルを初期化（削除）してから新しい連鎖を開始する

### 4.5 PostgreSQL は毎回フル

- `pg_dumpall` は論理バックアップであり、増分ダンプは原理的に不可
- WAL アーカイブ運用にすれば物理レベルで増分は可能だが、Immich 個人運用のスケールではオーバーキル
- → **フル / 差分どちらの回でも DB は毎回フル論理ダンプ**を取得する

---

## 5. 処理アーキテクチャ

### 5.1 全体フロー

```
[Immich コンテナ群]
   ├── pg_dumpall (docker exec)         ──→ /tmp/db_<date>.sql
   └── /mnt/hdd1/{library,upload,profile} ─┐
                                            ├─ tar (exclude thumbs/encoded-video/backups)
   docker-compose.yml / .env       ──────┘   │
                                              │  名前付きパイプ
                                              ▼
                                    [dd で 100GB ずつ切り出し]
                                              │
                                              ▼
                                       part_000, part_001, ...
                                              │
                                       2 並列で aws s3 cp
                                              │
                                              ▼
                              s3://bucket/full/<date>/part_NNN
                              （Glacier Deep Archive 直接 PUT）
```

### 5.2 一時ディスク使用量の制御（200GB 上限・2 並列）

- tar 出力をストリームのまま `aws s3 cp -` で送ると、中断時に再開不可（stdin は巻き戻せない）
- 一方、tar 出力を全部ローカルファイル化すると 500GB の一時容量が必要になる
- → **100GB ずつのチャンクに切り出し、できたものから順次アップロード → 削除** することで折衷
- **`dd` で名前付きパイプから逐次切り出す**ことで、ディスクに常駐するチャンクは「現在生成中の 1 つ + アップロード中の 1〜2 つ」に限定
- アップロード並列度 = 2 とすれば、ローカルに同時存在するチャンクは最大 2 個 ≒ **200GB**
- アップロードが詰まると `dd` の次の切り出しが進まない（自然なバックプレッシャー）

各チャンクは AWS CLI のマルチパートアップロードで送信され、ネットワーク断時はチャンク単位で自動リトライされる。

### 5.3 実装スクリプト（フルバックアップ）

`scripts/backup_full.sh`

```bash
#!/bin/bash
set -euo pipefail

# === 設定 ===
BACKUP_TMPDIR=/mnt/hdd1/.backup_tmp
SNAPSHOT_DIR=/mnt/hdd1/.backup_state
BUCKET=my-immich-backup
DATE=$(date -u +%Y%m%dT%H%M%SZ)
PREFIX="full/${DATE}"
PARALLEL=2
CHUNK_SIZE_MB=102400         # 100 GiB
COMPOSE_DIR=/home/tutti/immich

mkdir -p "$BACKUP_TMPDIR" "$SNAPSHOT_DIR"

# AWS CLI の multipart 設定（100GB オブジェクトはデフォルト 8MB チャンクだと
# 上限 10,000 parts に当たるため、100MB に拡張しておく）
aws configure set default.s3.multipart_chunksize 100MB

# === PostgreSQL ダンプ ===
DUMP="$BACKUP_TMPDIR/db_${DATE}.sql"
docker exec -t immich_postgres pg_dumpall -U postgres > "$DUMP"

# === フルなのでスナップショットを初期化 ===
SNAPSHOT="$SNAPSHOT_DIR/snapshot.snar"
rm -f "$SNAPSHOT"

# === 名前付きパイプ ===
PIPE="$BACKUP_TMPDIR/tar_pipe"
[[ -p "$PIPE" ]] || mkfifo "$PIPE"

# === tar をバックグラウンドで起動 ===
(
    tar --listed-incremental="$SNAPSHOT" \
        --exclude='./thumbs' \
        --exclude='./encoded-video' \
        --exclude='./backups' \
        -cf "$PIPE" \
        -C /mnt/hdd1 ./library ./upload ./profile \
        -C "$BACKUP_TMPDIR" "$(basename "$DUMP")" \
        -C "$COMPOSE_DIR" docker-compose.yml .env
) &
TAR_PID=$!

# === dd で 100GB ずつ切り出し → 並列アップロード ===
i=0
while :; do
    PART="$BACKUP_TMPDIR/part_$(printf '%03d' $i)"
    # iflag=fullblock 必須（pipe からの短い read を防ぐ）
    dd if="$PIPE" of="$PART" bs=1M count="$CHUNK_SIZE_MB" iflag=fullblock 2>/dev/null || true
    if [[ ! -s "$PART" ]]; then
        rm -f "$PART"
        break
    fi

    # 並列スロットが空くまで待つ
    while (( $(jobs -rp | wc -l) >= PARALLEL )); do
        wait -n
    done

    # チャンクをアップロード（成功したらローカル削除）
    (
        aws s3 cp "$PART" "s3://${BUCKET}/${PREFIX}/$(basename "$PART")" \
            --storage-class DEEP_ARCHIVE \
            --checksum-algorithm SHA256 \
            --no-progress \
            --metadata "backup-type=full,backup-date=${DATE}" \
        && rm -f "$PART"
    ) &

    ((i++))
done

wait "$TAR_PID"
wait   # 残りのアップロードを待つ

# === マニフェスト（リストア時にパーツ数を確認するため） ===
echo "{\"date\":\"${DATE}\",\"type\":\"full\",\"parts\":$i}" \
  | aws s3 cp - "s3://${BUCKET}/${PREFIX}/manifest.json" \
        --storage-class STANDARD

# === 後始末 ===
rm -f "$PIPE" "$DUMP"

# === スナップショットファイルもローカルでバックアップ ===
cp "$SNAPSHOT" "${SNAPSHOT}.bak"

# === 旧フルの削除（190日経過しているもののみ） ===
"$(dirname "$0")/cleanup_old_full.sh" "$DATE"

# === Slack 通知 ===
"$(dirname "$0")/notify_slack.sh" "full" "$DATE" "$i" "success"
```

### 5.4 実装スクリプト（差分バックアップ）

`scripts/backup_incremental.sh`

フルとほぼ同じだが、以下が異なる：

```bash
PREFIX="incremental/${DATE}"
SNAPSHOT="$SNAPSHOT_DIR/snapshot.snar"
# ※ rm -f "$SNAPSHOT" はしない（既存スナップショットを使って増分を判定）
```

`tar --listed-incremental=<既存ファイル>` を渡すと、tar が前回からの変更分のみを出力し、スナップショットファイルを更新する。

差分は通常サイズが小さい（数 GB 〜 数十 GB）ため、200GB 上限は実質的に問題にならない。

### 5.5 旧フル削除スクリプト

`scripts/cleanup_old_full.sh`

```bash
#!/bin/bash
set -euo pipefail
NEW_DATE=$1
BUCKET=my-immich-backup
NOW_EPOCH=$(date -u +%s)
RETENTION_DAYS=190

aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "full/" \
    --query "Contents[?contains(Key,'manifest.json')].[Key,LastModified]" \
    --output text | while read -r KEY LAST_MOD; do

    # 新しいフルは消さない
    [[ "$KEY" == *"$NEW_DATE"* ]] && continue

    UPLOAD_EPOCH=$(date -u -d "$LAST_MOD" +%s)
    AGE_DAYS=$(( (NOW_EPOCH - UPLOAD_EPOCH) / 86400 ))
    if (( AGE_DAYS >= RETENTION_DAYS )); then
        OLD_PREFIX=$(dirname "$KEY")
        echo "Deleting old full: $OLD_PREFIX (age=${AGE_DAYS}d)"
        aws s3 rm "s3://${BUCKET}/${OLD_PREFIX}/" --recursive
    fi
done
```

### 5.6 整合性確保（DB とメディアの一貫性）

- `pg_dumpall` は MVCC により DB 単体ではスナップショット時点で一貫している
- ただしメディアファイルとの間では、**DB ダンプ後に新規アップロードされた写真がメディア側にだけ存在する**ケースが起こりうる（リストア時に DB に未登録の "孤児" ファイルが復活）
- 対策案（運用判断）：
  - **A. 簡易**: DB ダンプ → メディア tar の順で取得し、孤児が出ても許容（現方針）
  - **B. 厳密**: `docker compose stop immich-server` でアップロードを止めてからバックアップ → 完了後に再開
- 個人運用 + 深夜実行であれば A で実害はほぼないので A を採用、ただし将来 B に切り替え可能な設計にしておく

---

## 6. AWS インフラ構成

### 6.1 S3

| 設定 | 値 |
|---|---|
| バケット名 | `my-immich-backup`（仮） |
| ストレージクラス | **Glacier Deep Archive を直接 PUT**（Standard 経由のライフサイクル遷移はコスト・最低保存期間カウントの観点で不利） |
| 暗号化 | **SSE-S3（AWS マネージドキー）** をデフォルト有効化 |
| バージョニング | 無効（誤削除対策はバックアップ運用側で担保） |
| **ライフサイクルルール** | ① `incremental/` 配下を 180 日で自動削除 ② **不完全なマルチパートアップロードを 7 日で破棄**（不可視オブジェクトの課金事故を防止）|
| パブリックアクセス | 全ブロック |

### 6.2 認証（IAM Roles Anywhere）

長期的な IAM アクセスキーをサーバーに置かないため、**IAM Roles Anywhere** を使用して X.509 証明書ベースで一時認証情報を発行する。

#### ざっくりとした使う流れ

1. **AWS 側（一度きり）**
   1. プライベート CA を用意（自前でも、AWS Private CA でも可）
   2. IAM Roles Anywhere で **Trust Anchor** を作成し、CA を登録
   3. バックアップ用 IAM ロール（`s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` などを最小権限で許可）を作成
   4. IAM Roles Anywhere で **Profile** を作成し、Trust Anchor とロールを紐付け
2. **Ubuntu サーバー側（一度きり）**
   1. CA 証明書から発行した、サーバー専用のクライアント証明書 + 秘密鍵を配置（例: `/etc/aws/cert.pem`, `/etc/aws/key.pem`、root 所有 0600）
   2. AWS 公式バイナリ `aws_signing_helper` を `/usr/local/bin` に配置
   3. `~/.aws/config` に `credential_process` を設定：
      ```
      [profile immich-backup]
      credential_process = /usr/local/bin/aws_signing_helper credential-process \
          --certificate /etc/aws/cert.pem \
          --private-key /etc/aws/key.pem \
          --trust-anchor-arn arn:aws:rolesanywhere:...:trust-anchor/... \
          --profile-arn       arn:aws:rolesanywhere:...:profile/... \
          --role-arn          arn:aws:iam::...:role/ImmichBackupRole
      ```
3. **運用**
   - `aws s3 cp --profile immich-backup ...` を叩くたびに、ヘルパーが証明書で署名 → 短命 (1h) なクレデンシャルを取得 → CLI に渡す
   - 漏洩疑い時は **AWS コンソールで Trust Anchor を無効化または証明書失効** で即時遮断可能
   - SSM ハイブリッドアクティベーションは「リモート管理機能」が不要なら採用しない（常駐エージェント `amazon-ssm-agent` が増えるため）

### 6.3 暗号化

- **SSE-S3（AWS マネージドキー）を採用**
- クライアントサイド暗号化（age / gpg 等）は今回は採用しない
- AWS 内部で復号可能ではあるが、個人運用での運用負荷とのトレードオフで現状は SSE-S3 を選択

### 6.4 死活監視（AWS 完結）

ローカルサーバーがダウンしているとそもそもバックアップが走らないため、**AWS 側でバックアップ実行を能動的に確認**する。

```
EventBridge Scheduler          Lambda                    Slack
   (毎日 04:00 UTC)  ───────▶  関数実行                 Incoming Webhook
                              │  ・S3 を ListObjects
                              │  ・直近 N 日に新しい
                              │    バックアップが
                              │    あるか確認
                              │  ・無ければ Slack 投稿
                              └─────HTTPS POST────────▶
```

- **Slack 通知方式**: SNS は経由せず、**Lambda から Slack Incoming Webhook を直接 HTTPS POST する**
  - 構成がシンプル（SNS トピック・サブスクリプション不要）
  - SNS の通知単価も浮く
  - Webhook URL は Lambda の環境変数か、Secrets Manager に格納
- 監視ロジック（擬似コード）:
  ```python
  import os, json, datetime, urllib.request, boto3
  s3 = boto3.client("s3")
  WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]
  BUCKET  = os.environ["BUCKET"]

  def lambda_handler(event, ctx):
      # 直近 8 日 (週次 +1日猶予) に incremental が来ているか
      cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=8)
      resp = s3.list_objects_v2(Bucket=BUCKET, Prefix="incremental/")
      latest = max((o["LastModified"] for o in resp.get("Contents", [])), default=None)
      ok = latest is not None and latest >= cutoff

      # フルは 200 日以内に新しいものがあること
      cutoff_full = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=200)
      resp_f = s3.list_objects_v2(Bucket=BUCKET, Prefix="full/")
      latest_f = max((o["LastModified"] for o in resp_f.get("Contents", [])), default=None)
      ok_full = latest_f is not None and latest_f >= cutoff_full

      # 現在のオブジェクト一覧（サイズ・更新日時）も Slack に流す
      summary = build_summary(resp, resp_f)

      msg = "✅ バックアップ正常" if (ok and ok_full) else "🚨 バックアップ異常検知"
      payload = {"text": f"{msg}\n```{summary}```"}
      req = urllib.request.Request(WEBHOOK, data=json.dumps(payload).encode(),
                                   headers={"Content-Type":"application/json"})
      urllib.request.urlopen(req)
  ```

### 6.5 月額コスト試算

#### S3 保管料金（Glacier Deep Archive: $0.00099/GB/月）

| 内訳 | 容量 | 月額 |
|---|---|---|
| フル（現世代） | ~500 GB | $0.50 |
| フル（旧世代、削除待ちの数日〜10日） | ~500 GB（一時的） | 平均 $0.05 |
| 差分（最大 26 世代 × 平均 5GB） | ~130 GB | $0.13 |
| **合計** | | **約 $0.7/月** |

#### S3 リクエスト料金（Glacier Deep Archive: $0.05/1,000 PUT）

- 100MB マルチパートチャンクで 100GB チャンク = 1,000 parts → 5 チャンク = 5,000 PUT/フル
- 年 2 回フル + 52 回差分（差分は parts 少なめ）→ 概算 30,000 PUT/年 → **$1.5/年 ≈ $0.13/月**

#### 死活監視（EventBridge Scheduler + Lambda + S3 LIST）

| サービス | 使用量（1 日 1 回） | 無料枠 | 月額 |
|---|---|---|---|
| EventBridge Scheduler | 30 invocations | 14M/月 always free | **$0** |
| Lambda 実行 | ~30 req × 5 秒 × 128MB ≒ 19 GB-秒 | 1M req + 400,000 GB-秒/月 always free | **$0** |
| S3 LIST | 30 LIST/月 | $0.005/1,000 LIST | **<$0.001** |
| CloudWatch Logs | 数 MB | 5 GB/月 always free | **$0** |
| Slack Webhook 送信 | (Lambda の egress) | 100 GB/月 outbound free | **$0** |

#### 月額合計

**約 $0.85 / 月（≈ 130 円）** + 初年度の Free Tier 切れ要素なし

転送料金（インバウンド）は **無料**。HDD 故障時のリストア（取り出し）は別計算（後述）。

---

## 7. Slack 通知の内容

毎回のバックアップ実行・死活監視 Lambda から以下を投稿する。

- **バックアップスクリプト側からの通知**（成功・失敗どちらも）
  - 種別（full / incremental）
  - 開始・終了時刻、所要時間
  - パーツ数、合計サイズ
  - 失敗時はエラーメッセージ
- **死活監視 Lambda からの通知（毎日）**
  - 直近のフル・差分が想定内に存在するか
  - 現在 S3 上に存在するバックアップオブジェクトの一覧（key, size, lastModified）
  - 異常時は明確に視認できる絵文字 / メンション

---

## 8. リストア

### 8.1 手順

1. AWS コンソールまたは CLI で、対象期間の **フル + 全差分** を Glacier Deep Archive から取り出しリクエスト（Standard or Bulk retrieval）
2. 取り出し完了通知を待つ（Standard: 12 時間、Bulk: 48 時間程度）
3. ローカルの作業ディレクトリにダウンロード
   ```bash
   aws s3 cp s3://my-immich-backup/full/<date>/ ./restore/full/ --recursive
   aws s3 cp s3://my-immich-backup/incremental/<date>/ ./restore/inc1/ --recursive
   # ... 必要な差分すべて
   ```
4. 各バックアップ世代の `part_*` を結合して tar として展開
   ```bash
   cat ./restore/full/part_* | tar --listed-incremental=/dev/null -xf - -C /mnt/hdd1
   cat ./restore/inc1/part_* | tar --listed-incremental=/dev/null -xf - -C /mnt/hdd1
   # ... 古い順に
   ```
5. PostgreSQL は同梱の SQL ダンプを `psql` でリストア
   ```bash
   docker exec -i immich_postgres psql -U postgres < db_<date>.sql
   ```
6. Immich を起動し、サムネイル・トランスコードジョブを再走させる

> 注：フル以降に Immich 上で削除した画像が、差分の解凍時に "孤児ファイル" として復活する可能性あり。これは許容する方針。

### 8.2 リストアコスト試算

500GB を Glacier Deep Archive から取り出す場合：

| 項目 | 単価 | 概算 |
|---|---|---|
| Standard retrieval | $0.02/GB | $10 |
| データ転送 (S3 → インターネット) | 約 $0.09/GB | $45 |
| GET リクエスト | $0.10/1,000 | <$0.01 |
| **合計** | | **約 $55** |

Bulk retrieval ($0.0025/GB) なら取り出し料金は $1.25 まで下がる（待ち時間 48h）。

---

## 9. 運用考慮事項

### 9.1 不完全なマルチパートアップロード対策

500GB 等の巨大オブジェクトをアップロード中に通信が切断されると、「不完全なマルチパートアップロード」として S3 上に不可視のデータが残り続け、課金対象になる。

→ **S3 ライフサイクルルールで「不完全なマルチパートアップロードを 7 日で破棄」を必須設定**

### 9.2 バックアップ検証

- アップロード時に AWS CLI の `--checksum-algorithm SHA256` で各 part の整合性を S3 側で検証させる
- ローカルでも `sha256sum` でハッシュを記録し、`manifest.json` に格納
- **年 1 回は別環境でリストアテストを実施**（実際に展開できることを確認しないと、バックアップが破綻していても気付けない）

### 9.3 スナップショットファイル（差分連鎖）の保護

- `snapshot.snar` を失うと、次回差分が事実上のフル相当のサイズになる
- 毎日 `cp snapshot.snar snapshot.snar.bak` でローカル冗長化
- フル取得時にも `snapshot.snar` の内容を S3 のフル prefix 配下にメタ情報として一緒に保管しておく（任意）

### 9.4 IAM 権限の最小化

バックアップ用 IAM ロールには、対象バケットに対する以下の最小権限のみを付与する：

- `s3:PutObject`
- `s3:AbortMultipartUpload`
- `s3:ListBucket`（旧フル削除判定用）
- `s3:DeleteObject`（旧フル削除用、prefix `full/` のみに限定）
- `s3:GetObjectAttributes`

---

## 10. 未決事項・将来検討

- **差分リストアの整合性リスクの軽減策**: 差分の途中 1 世代でも欠損すると以降が復元できないため、定期的にフル間隔を短くするか、合成フル（synthetic full）を採用するかを将来検討
- **クライアントサイド暗号化**: 現状は SSE-S3 で運用するが、より厳格にプライベートにしたい場合 age / gpg を tar 後段に挟む方式を再検討
- **Immich コンテナ停止 → バックアップ → 再開** 方式（5.6 の B 案）への切り替え判断
- 差分バックアップの曜日・時刻（仮：日曜 03:00）

---

## 11. 実装タスク

### AWS 側準備（できる限り CLI で実施）
- [ ] S3 バケット作成 + パブリックアクセス全ブロック
- [ ] S3 ライフサイクルルール設定
  - [ ] `incremental/` の 180 日自動削除
  - [ ] 不完全マルチパートアップロードの 7 日破棄
- [ ] SSE-S3 デフォルト暗号化の有効化
- [ ] IAM ロール作成（最小権限）
- [ ] IAM Roles Anywhere
  - [ ] CA 準備（AWS Private CA か外部 CA）
  - [ ] Trust Anchor 作成
  - [ ] Profile 作成
  - [ ] サーバー用クライアント証明書発行
- [ ] EventBridge Scheduler 用 Lambda 関数作成
- [ ] EventBridge Scheduler ルール作成（毎日 1 回）
- [ ] Slack Incoming Webhook URL 取得 → Lambda 環境変数 or Secrets Manager に格納

### Ubuntu サーバー側準備
- [ ] AWS CLI v2 インストール
- [ ] `aws_signing_helper` インストール
- [ ] `~/.aws/config` の `credential_process` 設定
- [ ] AWS CLI の `multipart_chunksize` を 100MB に設定
- [ ] `scripts/backup_full.sh` 配置・テスト
- [ ] `scripts/backup_incremental.sh` 配置・テスト
- [ ] `scripts/cleanup_old_full.sh` 配置・テスト
- [ ] `scripts/notify_slack.sh` 配置（バックアップ側からの直接通知）
- [ ] cron 登録（`0 3 1 1,7 *` フル / 週次差分）
- [ ] 一時ディレクトリ `/mnt/hdd1/.backup_tmp` の準備
- [ ] スナップショット保管ディレクトリ `/mnt/hdd1/.backup_state` の準備

### 検証
- [ ] 小規模データでフル / 差分の一連動作確認
- [ ] 中断シナリオ（ネットワーク断・プロセスキル）での再実行確認
- [ ] 別マシンでのリストアドリル
- [ ] 死活監視 Lambda の異常検知動作確認（バックアップを意図的に走らせない期間を作る）
