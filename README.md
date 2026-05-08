# Immich → S3 バックアップ

Immich のメディア・DB・設定を S3 Glacier Deep Archive に定常バックアップする一式。
設計の詳細は [`design.md`](./design.md) を参照。

## ディレクトリ構成

```
.
├── design.md                  # 設計書
├── .env.example               # 環境変数テンプレート
├── .github/workflows/         # GitHub Actions（self-hosted runner で auto-deploy）
├── aws-setup/                 # AWS 側の一回きりの準備（CLI スクリプト）
├── server-setup/              # Ubuntu サーバー側の準備
├── scripts/                   # 実運用で使うスクリプト
└── cron/                      # cron 登録テンプレート
```

## セットアップ手順

### 0. .env を作成

```bash
cp .env.example .env
$EDITOR .env   # S3_BUCKET, COMPOSE_DIR などを書き込む
```

`.env` は `.gitignore` 済み。Slack Webhook URL や ARN もここに集約する。

### 1. サーバー側：依存パッケージ + 証明書

```bash
./server-setup/01_install_dependencies.sh   # AWS CLI v2, signing helper, jq
./server-setup/02_generate_certs.sh         # /etc/aws/{ca-cert,ca-key,cert,key}.pem
```

`02` で生成した `ca-cert.pem` のパスを `.env` の `CA_CERT_PATH` に設定する（デフォルト `/etc/aws/ca-cert.pem`）。

### 2. AWS 側：admin 権限のある環境で順番に実行

`AWS_PROFILE` を一時的に admin プロファイルに切り替えて実行する想定。

```bash
# 1. S3 バケット作成 + パブリックアクセス全ブロック + SSE-S3
./aws-setup/01_create_bucket.sh

# 2. ライフサイクル: incremental 180日自動削除 + 不完全マルチパート 7日破棄
./aws-setup/02_apply_lifecycle.sh

# 3. バックアップ用 IAM ロール作成（権限は最小）
./aws-setup/03_create_iam_role.sh
# → 表示された ROLE_ARN を .env に書き写す

# 4. IAM Roles Anywhere (Trust Anchor + Profile)
./aws-setup/04_setup_roles_anywhere.sh
# → 表示された TRUST_ANCHOR_ARN, PROFILE_ARN を .env に書き写す

# 5. 死活監視 Lambda (Slack Webhook を直接叩く)
./aws-setup/05_create_lambda.sh

# 6. EventBridge Scheduler で毎日 04:00 UTC に Lambda 起動
./aws-setup/06_create_eventbridge_schedule.sh
```

### 3. サーバー側：AWS プロファイル設定

`.env` に ARN 三点が揃ってから：

```bash
./server-setup/03_configure_aws_profile.sh

# 動作確認（短命クレデンシャルで s3 が見えるか）
source .env
aws s3 ls "s3://$S3_BUCKET" --profile "$AWS_PROFILE"
```

### 4. 試運転

最初は小さなデータセットで通しテストするのが安全：

```bash
# 引数なしで即実行。Slack に SUCCESS / FAILED が届けば OK
./scripts/backup_full.sh

# 直後にもう一度 incremental を回す。差分は数 KB 程度になるはず
./scripts/backup_incremental.sh
```

S3 上に `full/<date>/part_NNN` と `manifest.json` が並んでいることを確認。

### 5. cron 登録

```bash
crontab cron/immich-backup.crontab
crontab -l   # 確認
```

ログは `/var/log/immich-backup.log` に追記される（書き込み権限を要付与、または crontab 内のパスを変更）。

### 6. (任意) GitHub Actions 自動デプロイを有効化

self-hosted runner を同じ Ubuntu サーバーに置いて、main 更新を自動で `/opt/immich-backup-s3/` に同期 + AWS リソース更新まで一気通貫にできる。`scripts/` や `aws-setup/` の改変を `git push` だけで反映できるようになる。

詳細は下の「Auto-deploy」セクション。

## Auto-deploy via GitHub Actions

### アーキテクチャ

```
git push origin main
        │
        ▼
GitHub Actions
        │  (self-hosted runner trigger)
        ▼
Ubuntu サーバー（gh-runner ユーザーで稼働する systemd サービス）
        │
        ├─ rsync で /opt/immich-backup-s3/ に同期 (.env は保持)
        └─ AWS OIDC で短命クレデンシャル取得 → Lambda / Lifecycle / Schedule 更新
```

cron は `/opt/immich-backup-s3/scripts/...` を参照しているので、`git push` だけでバックアップロジックの変更が反映される。

### ⚠️ セキュリティ前提

公開リポジトリ + self-hosted runner は、fork からの PR が runner 上で任意コードを実行できる構造的リスクがある。本構成では以下で抑止：

- workflow を `on: push: branches: [main]` のみで起動。`pull_request` トリガーは無し → fork からは触れない
- リポジトリの Settings → Actions → "Fork pull request workflows from outside collaborators" を **Require approval** に
- 心配なら **リポジトリを private 化**（一番安全）

### セットアップ手順

#### a. AWS 側：CI 用デプロイロールを作成（admin 権限で1回）

```bash
# .env の GITHUB_REPO を埋めてから
./aws-setup/00_bootstrap_ci.sh
```

実行すると以下を作成：
- GitHub OIDC プロバイダ（既にあれば再利用）
- `ImmichBackupCIDeployRole`（trust は `repo:<owner>/<repo>:ref:refs/heads/main` に限定、permission は Lambda update + Lifecycle put + Schedule update のみの最小権限）

スクリプトの末尾に、GitHub に登録すべき repository secret 一覧が出力される。

#### b. GitHub repository secrets を設定

`https://github.com/<owner>/<repo>/settings/secrets/actions` で：

| Secret | 値 |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | `00_bootstrap_ci.sh` が出力した role ARN |
| `AWS_REGION` | `ap-northeast-1` など |
| `S3_BUCKET` | バケット名 |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL |

#### c. サーバー側：self-hosted runner をインストール

GitHub の `Settings → Actions → Runners → New self-hosted runner` で1時間有効な登録トークンを発行し、それを渡してインストール：

```bash
GITHUB_RUNNER_TOKEN="AAAA..." ./server-setup/04_install_github_runner.sh
```

これで以下が完了：
- `gh-runner` システムユーザー作成（シェルログイン不可）
- `/opt/actions-runner/` に runner バイナリ配置・登録
- `actions.runner.<repo>.<host>.service` を systemd サービス化（自動起動）
- `/opt/immich-backup-s3/` を `gh-runner:gh-runner` 所有の 0755 で作成（cron ユーザーが読める）

#### d. 初回デプロイ

```bash
git push origin main   # または GitHub UI から workflow_dispatch
```

成功したら：

```bash
# 同期先を確認
ls -la /opt/immich-backup-s3/

# 一度だけ手動で .env を配置（rsync の exclude で以後は保持される）
sudo install -o $(whoami) -m 0640 ~/repos/immich-backup-s3/.env /opt/immich-backup-s3/.env
```

#### e. cron を `/opt/immich-backup-s3/` 配下に向ける

```bash
crontab /opt/immich-backup-s3/cron/immich-backup.crontab
```

以後は `git push` するだけで scripts と Lambda が更新される。

## 運用メモ

- **死活監視**: 毎日 04:00 UTC（13:00 JST）に Lambda が S3 を見て、最新フル/差分が閾値（フル 200日 / 差分 8日）以内になければ Slack に :rotating_light: を投げる。閾値は Lambda の環境変数 `FULL_MAX_AGE_DAYS` / `INCREMENTAL_MAX_AGE_DAYS` で変更可。
- **バックアップ通知**: 各バックアップスクリプトが完了/失敗時に Slack へ通知（バックアップサーバー由来）。
- **旧フル削除**: フル成功後に `cleanup_old_full.sh` が `manifest.json` の LastModified を見て **190日以上経過したフル prefix** を削除（Glacier Deep Archive 最低保存期間 180日 + 10日バッファ）。
- **不完全マルチパート**: ライフサイクルで 7 日後に自動破棄（課金事故防止）。
- **整合性**: バックアップ間で DB と メディアが完全に同期しているわけではない（孤児ファイル可能性）。許容方針。
- **スナップショット保護**: `snapshot.snar` を失うと差分連鎖が壊れるので、毎バックアップ後に `.bak` をローカルに作っている。

## リストア

`scripts/restore.sh` 参照。Glacier Deep Archive は取り出しが非同期なので二段階：

```bash
# 1. 取り出しリクエスト（Standard で 12h, Bulk で 48h）
./scripts/restore.sh request 20260101T030000Z 20260108T030000Z 20260115T030000Z

# 2. 取り出し完了後、ダウンロード + 展開
./scripts/restore.sh extract 20260101T030000Z 20260108T030000Z 20260115T030000Z
```

利用可能なバックアップ一覧：

```bash
./scripts/restore.sh list
```

## 月額コスト目安

詳細は `design.md` 6.5。500 GB 規模で **約 $0.85 / 月**。Lambda + EventBridge + LIST は AWS Free Tier の always-free 枠内で実質 $0。

## トラブルシュート

- `aws s3 ls` が `Unable to locate credentials` を返す → `aws_signing_helper` のパス、cert/key の権限、`.env` の ARN を確認
- 差分バックアップで `snapshot file missing` → 直前にフルが走っていない。`backup_full.sh` を先に
- Lambda が Slack に流れない → CloudWatch Logs `/aws/lambda/ImmichBackupMonitor` を確認
- Glacier Deep Archive 早期削除課金が出た → `cleanup_old_full.sh` が 180 日未満を削除している。`RETENTION_DAYS` を確認
