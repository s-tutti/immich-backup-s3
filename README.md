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

## サーバー側のユーザー設計

このプロジェクトでは、Immich コンテナのファイルを所有する既存の `immich` ユーザーを以下の **すべての用途** で再利用する：

- バックアップスクリプトの実行（cron）
- GitHub Actions self-hosted runner の実行
- AWS CLI のクレデンシャル所有者（`/home/immich/.aws/`）
- GitHub への git 操作用 SSH キー所有者（`/home/immich/.ssh/`）

参考までに想定する `/etc/passwd` エントリと docker-compose の対応：

```
$ sudo grep immich /etc/passwd
immich:x:997:984::/home/immich:/usr/sbin/nologin

$ grep -B1 -A2 'user:' docker-compose.yml
  immich-server:
    container_name: immich_server
    user: "997:984"
```

`/usr/sbin/nologin` でも cron / systemd / `sudo -u immich -H` はすべて機能するので、対話ログイン不可のままで問題ない。`UPLOAD_LOCATION` のファイルは既にこのユーザーが所有しているため、追加のグループ設定は最小限で済む。

## サーバー側の事前セットアップ（一回きり）

### A. SSH キー生成 + GitHub Deploy Key 登録

`immich` ユーザーから GitHub に対して `git clone` / `git pull` できるようにする。
self-hosted runner の `actions/checkout` 自体は HTTPS + 自動トークンで動くが、
**初回ブートストラップでのリポジトリ取得 + 障害時の手動 `git pull` フォールバック** に
このキーが必要。

```bash
# 1. .ssh ディレクトリ作成
sudo mkdir -p /home/immich/.ssh
sudo chmod 700 /home/immich/.ssh
sudo chown immich:immich /home/immich/.ssh

# 2. SSH キー生成（パスフレーズなし。非対話運用のため）
sudo -u immich ssh-keygen -t ed25519 -C "immich-backup" \
    -f /home/immich/.ssh/id_ed25519 -N ""

# 3. GitHub の host key を known_hosts に登録（cron 等の非対話 SSH で必要）
sudo -u immich -H bash -c \
    'ssh-keyscan github.com >> /home/immich/.ssh/known_hosts'

# 4. 公開鍵を表示し、GitHub の Deploy Key として登録
cat /home/immich/.ssh/id_ed25519.pub
# → https://github.com/<owner>/<repo>/settings/keys → "Add deploy key"
#   タイトルは任意（例: "immich-server"）。Read-only で OK（push は Actions 経由）
```

### B. 権限の整備

```bash
# pg_dumpall を docker exec 経由で叩くため、docker グループに追加
sudo usermod -aG docker immich

# AWS 証明書を immich が読めるように
#   ※ 02_generate_certs.sh が出力した /etc/aws/{cert,key}.pem に対して
sudo chgrp immich /etc/aws/cert.pem /etc/aws/key.pem
sudo chmod 0640   /etc/aws/cert.pem /etc/aws/key.pem
# CA 鍵 (ca-key.pem) は root 専用のまま (0600 root:root)

# バックアップ用一時領域・スナップショット領域
sudo install -d -o immich -g immich -m 0700 /mnt/hdd1/.backup_tmp
sudo install -d -o immich -g immich -m 0700 /mnt/hdd1/.backup_state

# cron が書き込むログファイル
sudo install -o immich -g immich -m 0644 /dev/null /var/log/immich-backup.log
```

### C. 初回リポジトリ取得（ブートストラップ）

`/opt/immich-backup-s3/` がまだ何も無いので、Deploy Key を使って初回 clone する：

```bash
sudo install -d -o immich -g immich -m 0750 /opt/immich-backup-s3
sudo -u immich -H git clone \
    git@github.com:s-tutti/immich-backup-s3.git \
    /opt/immich-backup-s3
```

以降は Actions が main 更新を自動で `/opt/immich-backup-s3/` に rsync する。
Actions が壊れた時の手動フォールバックは：

```bash
sudo -u immich -H git -C /opt/immich-backup-s3 pull
```

> Actions 自動デプロイを使わずに **完全手動運用** で進めるなら、以降の手順を `/opt/immich-backup-s3/` 直下で実行すれば OK（このリポジトリ自体がランタイム）。

## セットアップ手順

### 0. .env を作成

`/opt/immich-backup-s3/` 直下に `.env` を作る（`immich` ユーザー所有・0600）：

```bash
sudo -u immich -H cp /opt/immich-backup-s3/.env.example /opt/immich-backup-s3/.env
sudo chmod 0600 /opt/immich-backup-s3/.env
sudo $EDITOR /opt/immich-backup-s3/.env   # S3_BUCKET, GITHUB_REPO 等を書く
```

`.env` は `.gitignore` 済み + rsync の `--exclude` 対象なので、Actions のデプロイで上書きされない。

### 1. サーバー側：依存パッケージ + 証明書

```bash
cd /opt/immich-backup-s3

# どちらも root が必要なので sudo で実行
sudo ./server-setup/01_install_dependencies.sh   # AWS CLI v2, signing helper, jq
sudo ./server-setup/02_generate_certs.sh         # /etc/aws/{ca-cert,ca-key,cert,key}.pem
```

`02` 実行後、上の **B. 権限の整備** で示した `chgrp immich` / `chmod 0640` を `cert.pem` と `key.pem` に必ず適用する（immich ユーザーが読めないと runner / cron が AWS を呼べない）。

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

`.env` に ARN 三点（`ROLE_ARN` / `TRUST_ANCHOR_ARN` / `PROFILE_ARN`）が揃ってから、**immich ユーザーとして** 設定する（プロファイルは `/home/immich/.aws/config` に書かれる）：

```bash
sudo -u immich -H /opt/immich-backup-s3/server-setup/03_configure_aws_profile.sh

# 動作確認（短命クレデンシャルで s3 が見えるか）
sudo -u immich -H bash -c \
    'source /opt/immich-backup-s3/.env && aws s3 ls "s3://$S3_BUCKET" --profile "$AWS_PROFILE"'
```

### 4. 試運転

immich ユーザーで実行する：

```bash
# 引数なしで即実行。Slack に SUCCESS / FAILED が届けば OK
sudo -u immich -H /opt/immich-backup-s3/scripts/backup_full.sh

# 直後にもう一度 incremental を回す。差分は数 KB 程度になるはず
sudo -u immich -H /opt/immich-backup-s3/scripts/backup_incremental.sh
```

S3 上に `full/<date>/part_NNN` と `manifest.json` が並んでいることを確認。

### 5. cron 登録

immich ユーザーの crontab にインストール：

```bash
sudo crontab -u immich /opt/immich-backup-s3/cron/immich-backup.crontab
sudo crontab -u immich -l   # 確認
```

ログは `/var/log/immich-backup.log`（**B. 権限の整備** で immich 所有・0644 で作成済み）。

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

GitHub の `Settings → Actions → Runners → New self-hosted runner` で 1 時間有効な登録トークンを発行し、それを渡してインストール：

```bash
sudo bash -c 'GITHUB_RUNNER_TOKEN="AAAA..." \
    /opt/immich-backup-s3/server-setup/04_install_github_runner.sh'
```

スクリプトが行うこと（既定値で `RUNNER_USER=immich`）：

- `immich` ユーザーを **再利用**（無ければ作成）
- `/home/immich/actions-runner/` に runner バイナリ配置・登録
- `actions.runner.<owner>-<repo>.<host>.service` を systemd 化（boot 時自動起動）
- `/opt/immich-backup-s3/` を `immich:immich` 所有 0750 で確保

`.env` の `RUNNER_USER` を変えれば別ユーザーにもできる。

#### d. 初回デプロイ

```bash
git push origin main   # または GitHub UI から workflow_dispatch
```

`/opt/immich-backup-s3/` に main の内容が rsync される。`.env` は **B. 初回ブートストラップで配置済み** のものが `--exclude` で保持されるので、上書きされない。

#### e. cron を有効化

cron は **5. cron 登録** ですでに登録済みのはず。`/opt/immich-backup-s3/scripts/...` を参照しているので、以降 `git push` するだけでバックアップロジック・Lambda・ライフサイクルが自動更新される。

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
