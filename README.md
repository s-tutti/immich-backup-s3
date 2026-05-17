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
# 0. /home/immich 自体を immich 所有に
#    Immich を docker-compose で動かしているだけだとこのディレクトリが root 所有のまま
#    だったり、そもそも存在しないことがある。immich が書き込めないと .ssh / .aws を
#    作れず、aws_signing_helper も動かない。
sudo install -d -o immich -g immich -m 0750 /home/immich

# 1. .ssh ディレクトリ作成
sudo install -d -o immich -g immich -m 0700 /home/immich/.ssh

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

# AWS 証明書: クライアント秘密鍵 (key.pem) を immich が読めるように
#   ※ 02_generate_certs.sh が ca-cert.pem / cert.pem は 0644、ca-key.pem / key.pem は
#     0600 で root 所有として作成する。key.pem だけ immich が読めるよう緩める。
sudo chgrp immich /etc/aws/key.pem
sudo chmod 0640   /etc/aws/key.pem
# ca-key.pem (CA 秘密鍵) は root 専用のまま — Immich サーバー外には出さない

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

以降は Actions が main 更新を自動で `/opt/immich-backup-s3/` に rsync する。`.git/` も同期対象（runner 側が `actions/checkout@v4` の既定で shallow なので数十KB）。デプロイ済みの commit は `git -C /opt/immich-backup-s3 rev-parse HEAD` で確認可。

Actions が壊れた時の手動フォールバック。Actions 経由のデプロイ後は `.git/` が shallow になっているので、`pull` ではなく `fetch --depth=1` + `reset --hard` でリモート HEAD に合わせる：

```bash
sudo -u immich -H git -C /opt/immich-backup-s3 fetch --depth=1 origin main
sudo -u immich -H git -C /opt/immich-backup-s3 reset --hard origin/main
```

初回ブートストラップ直後（フル clone のまま、まだ Actions が走っていない時）は素直に `pull` でも OK：

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

#### Slack Incoming Webhook URL の取得

`SLACK_WEBHOOK_URL` には Slack の **Incoming Webhook URL**（`https://hooks.slack.com/services/Txxx/Bxxx/yyy` の形式）を入れる。バックアップ通知（成功/失敗）と日次の死活監視 Lambda が、このエンドポイントへ HTTPS POST で投稿する。

1. **Slack App を作成** — <https://api.slack.com/apps> → `Create New App` → `From scratch`
   - App Name: 任意（例: `Immich Backup Notifier`）
   - Workspace: 通知を流したい Slack ワークスペースを選択
2. **Incoming Webhooks を有効化** — 作成した App の左メニュー → `Incoming Webhooks` → トグルを `On`
3. **チャネル指定で URL を発行** — 同ページ下部 `Add New Webhook to Workspace` → 通知先チャネルを選択 → `Allow`
4. 戻ってきた画面の `Webhook URL` 欄をコピー
5. `.env` に貼り付け：
   ```bash
   export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T.../B.../..."
   ```
6. 動作確認（curl で投稿してみる）：
   ```bash
   source /opt/immich-backup-s3/.env
   curl -fsS -X POST -H 'Content-Type: application/json' \
     --data '{"text":"webhook 接続テスト :white_check_mark:"}' \
     "$SLACK_WEBHOOK_URL"
   ```
   選択したチャネルにメッセージが流れれば OK。

> ⚠️ **URL は事実上の認証情報**（知っている人なら誰でもチャネルに投稿できる）。`.env` は 0600 で管理し、git にコミットしない。GH Actions では repo secrets に登録する（後述）。漏洩したら Slack App 設定画面から `Revoke` して新しい URL を発行する。

### 1. サーバー側：依存パッケージ + 証明書

```bash
cd /opt/immich-backup-s3

# どちらも root が必要なので sudo で実行
sudo ./server-setup/01_install_dependencies.sh   # AWS CLI v2, signing helper, jq
sudo ./server-setup/02_generate_certs.sh         # /etc/aws/{ca-cert,ca-key,cert,key}.pem
```

`02` 実行後、上の **B. 権限の整備** で示した `chgrp immich` / `chmod 0640` を `cert.pem` と `key.pem` に必ず適用する（immich ユーザーが読めないと runner / cron が AWS を呼べない）。

### 2. AWS 側：admin 権限のある環境で順番に実行

`aws-setup/` 配下のスクリプトは IAM ロール作成・OIDC プロバイダ作成・Lambda 作成など **admin 権限が必要**。Immich サーバーでなく、**手元の管理用マシンから実行するのが推奨**（admin クレデンシャルを Immich サーバー上に置く必要がない）。

管理マシンに必要なものは最小限：

- AWS CLI v2
- admin 権限の AWS クレデンシャル（`[default]` プロファイル or 環境変数）
- `jq`（04 で使用）, `zip`（05 で Lambda 関数を packaging するのに使用）
  ```bash
  sudo apt install -y jq zip awscli   # awscli は v2 を別途入れるならスキップ
  ```
- このリポジトリのチェックアウト
- `.env`（`S3_BUCKET` / `AWS_REGION` / `GITHUB_REPO` / `SLACK_WEBHOOK_URL` だけ埋まっていれば 00–06 全部動く。`UPLOAD_LOCATION` 等のサーバー固有パスは未使用なので空でも可）

`04_setup_roles_anywhere.sh` のみ `CA_CERT_PATH` の PEM ファイルを参照するので、Immich サーバー側で `server-setup/02_generate_certs.sh` を先に走らせて CA を作っておき、`ca-cert.pem` を管理マシンへ持ってくる：

```bash
# 管理マシン側
ssh tutti@<immich-server> 'sudo cat /etc/aws/ca-cert.pem' > ca-cert.pem
# .env で CA_CERT_PATH を ./ca-cert.pem に書き換えてから 04 を実行
```

`ca-cert.pem` は公開証明書なので外部持ち出し OK。`ca-key.pem`（CA 秘密鍵）は **絶対に Immich サーバー外へ出さない**（Roles Anywhere の Trust Anchor 登録には不要）。

`.env` の `AWS_PROFILE=immich-backup` は **runtime 用**（IAM Roles Anywhere の短命クレデンシャル取得プロファイル）で bootstrap には使えない。各スクリプトは `.env` を source した後、**呼び出し元が事前に `AWS_PROFILE` を export していなければ `unset`、していれば尊重** するようになっている。

#### admin クレデンシャルの渡し方（どれか1つ）

```bash
# A. [default] プロファイルに admin keys を入れている場合
./aws-setup/00_bootstrap_ci.sh

# B. 別名 (admin など) の admin プロファイルを使う場合
AWS_PROFILE=admin ./aws-setup/00_bootstrap_ci.sh
# 事前 export した AWS_PROFILE は .env の値より優先される

# C. 環境変数で admin keys を渡す場合
AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... ./aws-setup/00_bootstrap_ci.sh
```

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

logrotate を登録して weekly でローテーション（`rotate 12` = 約3か月保持、gzip 圧縮）:

```bash
sudo install -m 0644 -o root -g root \
    /opt/immich-backup-s3/server-setup/immich-backup.logrotate \
    /etc/logrotate.d/immich-backup
sudo logrotate --debug /etc/logrotate.d/immich-backup   # syntax 検証 (実ローテーションはしない)
```

クライアント証明書（IAM Roles Anywhere 用、デフォルト 1 年有効）の自動更新も同時に登録する。root crontab に入れる（CA 秘密鍵 `/etc/aws/ca-key.pem` が root 0600 のため）：

```bash
sudo crontab -u root /opt/immich-backup-s3/cron/immich-cert-renew.crontab
sudo crontab -u root -l   # 確認
```

毎月 1 日 04:00 に `scripts/renew_client_cert.sh` が走り、残 60 日以下なら同じ CA で再発行 + Slack に :sparkles:。動作確認は `sudo FORCE=1 /opt/immich-backup-s3/scripts/renew_client_cert.sh` で。

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

- **死活監視**: 毎日 04:00 UTC（13:00 JST）に Lambda が S3 をチェック。最新フル/差分が閾値（フル 200日 / 差分 8日）を超えていれば Slack に :rotating_light: を投げる。閾値は Lambda の環境変数 `FULL_MAX_AGE_DAYS` / `INCREMENTAL_MAX_AGE_DAYS` で変更可。**Slack 通知は ALERT 時のみ。ただし月曜は週次サマリとして OK 時も投稿する**（バックアップは日曜実行なので、月曜の通知が直近の生存確認になる。火〜土はサイレント実行で Lambda / Scheduler 自体の死活確認のみ）。
- **バックアップ通知**: 各バックアップスクリプトが完了/失敗時に Slack へ通知（バックアップサーバー由来）。SUCCESS 通知の Slack 投稿は `|| true` で握りつぶしているので、Slack 側の一時障害が「バックアップ失敗」扱いにならない（データは S3 まで届いている）。
- **並行実行ガード**: cron 側で `flock -n /tmp/immich-backup.lock` を被せている。`1/1` か `7/1` が日曜になると full と incremental が同時刻に走るが、その場合は full が先にロックを取り、その回の incremental は何もせず終了する（意図通り）。
- **クライアント証明書の自動更新**: `cron/immich-cert-renew.crontab` を root の crontab に登録すると、毎月 1 日 04:00 に `scripts/renew_client_cert.sh` が走り、IAM Roles Anywhere 用クライアント証明書の残日数を点検する。60 日以下なら同じ CA（`/etc/aws/ca-*.pem`）で再発行（既定 730 日有効）+ Slack に :sparkles:。Trust Anchor は CA に紐付くので AWS 側の再登録は不要。失敗時は :rotating_light:。手動で試したい時は `sudo FORCE=1 /opt/immich-backup-s3/scripts/renew_client_cert.sh`。
- **証明書失効時の検知経路**: 万一更新を逃して失効した場合でも、次回 cron でバックアップが走った時に `aws s3 cp` が認証失敗 → スクリプト内 `trap on_error` が Slack に FAILED を投げる（webhook は AWS 認証を使わないので機能する）。さらに 8 日以内に Lambda 監視も :rotating_light: を出す。
- **旧フル削除**: フル成功後に `cleanup_old_full.sh` が `manifest.json` の LastModified を見て **190日以上経過したフル prefix** を削除（Glacier Deep Archive 最低保存期間 180日 + 10日バッファ）。
- **不完全マルチパート**: ライフサイクルで 7 日後に自動破棄（課金事故防止）。
- **整合性**: バックアップ間で DB と メディアが完全に同期しているわけではない（孤児ファイル可能性）。許容方針。
- **スナップショット保護**: `snapshot.snar` を失うと差分連鎖が壊れるので、毎バックアップ後に `.bak` をローカルに作っている。
- **journald の上限**: GitHub Actions self-hosted runner や cert renew 等のログは systemd-journald に流れる。デフォルトは無制限なので、初期セットアップで `sudo journalctl --vacuum-size=1G` 程度に絞っておくか、`/etc/systemd/journald.conf` に `SystemMaxUse=1G` を設定しておくとディスクを食い潰さない。`journalctl --disk-usage` で現状確認できる。

## リストア

`scripts/restore.sh` 参照。Glacier Deep Archive は取り出しが非同期なので二段階（リクエスト → 待機 → 展開）。

### 災害復旧（最新状態に戻したい場合・推奨）

引数なしで起動すると **「最新フル + そのフル以降の全差分」** を S3 から自動抽出して使うので、半年運用後で差分が 26 個あっても 1 行で済みます：

```bash
# 0. 何が復元対象になるかプレビュー（dry-run、コストもアクションも発生しない）
sudo -u immich -H bash -c "
    source /opt/immich-backup-s3/.env
    /opt/immich-backup-s3/scripts/restore.sh latest
"
# → "Restore chain:
#      full/20260509T125322Z
#      incremental/20260510T122843Z
#      ...
#    Total: 1 full + N incremental"
#    内容を見て、復元したい組み合わせと一致しているか確認

# 1. 取り出しリクエスト（auto-discover、Bulk で約 $1、48h 待ち）
sudo -u immich -H bash -c "
    source /opt/immich-backup-s3/.env
    RETRIEVAL_TIER=Bulk \
    /opt/immich-backup-s3/scripts/restore.sh request
"

# 2. 48h 経過後、ダウンロード + 展開（同じ chain を auto-discover）
sudo -u immich -H bash -c "
    source /opt/immich-backup-s3/.env
    /opt/immich-backup-s3/scripts/restore.sh extract
"
```

`Standard` Tier (12h, $0.02/GB) を使いたければ `RETRIEVAL_TIER=Standard` を指定。

### 過去の特定時点に戻したい場合（PITR / drill）

タイムスタンプを **明示的に引数指定** することで、auto-discover を上書き：

```bash
./scripts/restore.sh request 20260101T030000Z 20260108T030000Z 20260115T030000Z
./scripts/restore.sh extract 20260101T030000Z 20260108T030000Z 20260115T030000Z
```

並びは「フル（最初の引数）→ 差分（古い順）」。

### 補助コマンド

| コマンド | 用途 |
|---|---|
| `restore.sh latest` | auto-discover が選ぶ chain をプレビュー（DR を打つ前の確認に） |
| `restore.sh list` | バケット内の **全 prefix を生で一覧**（旧フル含む。整理確認用） |
| `restore.sh request [<ts> ...]` | Glacier 取り出しリクエスト（auto or 明示） |
| `restore.sh extract [<ts> ...]` | ダウンロード + tar 展開（auto or 明示） |

`latest` と `list` の使い分け：

- `latest`：**DR で復元される世代の組み合わせ** だけ（=「今 request したら何が取れるか」のプレビュー）
- `list`：**バケット内の全履歴を生で**（過去のフルや、旧フル系列の差分も含む）

### 復元したファイルを Immich に取り込む手順（DR 本番）

`restore.sh extract` で `$TARGET_DIR`（既定 `/mnt/hdd1_restored`、ドリルでは `/mnt/hdd1/drill_target`）に以下が展開された状態：

```
$TARGET_DIR/
├── library/                  ← オリジナル写真・動画
├── upload/                   ← 同上
├── profile/                  ← アバター
├── db_<TS_最新>.sql           ← 最新の DB ダンプ（実際に流し込むのはコレ）
├── db_<TS_中間>.sql           ← 古い世代の DB ダンプ（無視）
├── db_<TS_フル>.sql           ← 同上
├── docker-compose.yml        ← 復元元の構成
└── .env                      ← 復元元の環境変数
```

ここから Immich を起動・稼働させる手順は以下：

#### 1. live の postgres データを **持ち込まない** で Immich をセットアップ

> ⚠️ **重要**：DR で別マシンに復元する場合・既存環境を作り直す場合・ドリルで別 compose を立てる場合、いずれも **既存の `postgres/` データディレクトリを流用してはいけない**。S3 dump を流し込むには **空の PostgreSQL データディレクトリ** が必要（pg_dumpall は `CREATE DATABASE` から含む）。
>
> 既存環境を流用する旧 `postgres/` データがあれば消すか、新しいパスに切り替える：
>
> ```bash
> # 例1: live 環境を再構築する場合（live はもう死んでいる前提）
> sudo rm -rf /home/tutti/immich-app/postgres
> sudo install -d -o immich -g immich /home/tutti/immich-app/postgres   # 空に
>
> # 例2: 別ディレクトリを使う場合、.env で切り替え
> # DB_DATA_LOCATION=./postgres-restored
> sudo install -d -o immich -g immich /home/tutti/immich-app/postgres-restored
> ```

#### 2. docker-compose.yml と .env を取り戻す（or 既存を流用）

復元データの `$TARGET_DIR/docker-compose.yml` と `$TARGET_DIR/.env` は **バックアップ取得時点の構成**。Immich のバージョンアップ等で live と差分があるかもしれないので、`diff` で確認してから採用するか既存を温存するか判断：

```bash
sudo diff /home/tutti/immich-app/docker-compose.yml "$TARGET_DIR/docker-compose.yml"
sudo diff /home/tutti/immich-app/.env              "$TARGET_DIR/.env"
```

新規セットアップなら復元データのものをそのまま採用：

```bash
sudo cp "$TARGET_DIR/docker-compose.yml" /home/tutti/immich-app/
sudo cp "$TARGET_DIR/.env"              /home/tutti/immich-app/
```

ただし `.env` の `UPLOAD_LOCATION` は復元したメディアの実体（後述）を指すように調整。

#### 3. メディアを `UPLOAD_LOCATION` に配置

`$TARGET_DIR/{library,upload,profile}/` を Immich の `UPLOAD_LOCATION`（通常 `/mnt/hdd1`）にそのまま展開：

```bash
# 例: UPLOAD_LOCATION=/mnt/hdd1 で運用する場合
sudo mv "$TARGET_DIR/library"  /mnt/hdd1/
sudo mv "$TARGET_DIR/upload"   /mnt/hdd1/
sudo mv "$TARGET_DIR/profile"  /mnt/hdd1/
sudo chown -R immich:immich /mnt/hdd1/{library,upload,profile}
```

または `UPLOAD_LOCATION` 自体を `$TARGET_DIR` に向けてしまう（手抜きルート、ドリルで便利）：

```bash
# Immich の .env で:
# UPLOAD_LOCATION=/mnt/hdd1/drill_target
```

#### 4. Postgres を空起動 → dump を流し込む

`postgres/` が空の状態で Immich を起動すると、コンテナが初期化スクリプトを走らせて空の DB ができる。その後 dump を流し込む：

```bash
cd /home/tutti/immich-app
sudo docker compose up -d postgres            # postgres だけ先に起動
sleep 10
sudo docker exec immich_postgres pg_isready -U postgres   # ready 待ち

# 最新の dump を選んで投入 (pg_dumpall は CREATE DATABASE 含むので空 DB OK)
LATEST_DUMP=$(sudo ls -t "$TARGET_DIR"/db_*.sql | head -1)
sudo docker exec -i immich_postgres psql -U postgres < "$LATEST_DUMP"
```

#### 5. Immich の他コンテナを起動

```bash
sudo docker compose up -d
sudo docker compose logs -f immich-server | head -50   # 起動ログを確認
```

`http://<server>:2283` でアクセスして、復元前と同じユーザー ID / パスワードでログインできれば成功（DB がちゃんと復元されてる証拠）。

#### 6. （任意）バックアップ用 marker と snapshot をリセット

復元直後は live と marker のタイムスタンプがずれている。次回 cron 差分が走るときに「全データが新しい扱い」になって巨大な差分が出るのを避けたければ：

```bash
# 復元直後にフルバックアップを 1 回手動で取って、marker を最新化
sudo -u immich -H /opt/immich-backup-s3/scripts/backup_full.sh
```

これで以降の差分は通常通り。

#### 7. 除外していたファイルを再生成 → 次のセクションへ

### リストア後に再生成すべきもの（除外していたファイルの復元）

バックアップでは **`thumbs/`** `encoded-video/` **`backups/`** を除外しているので、リストア直後の Immich は「データは全部あるけどサムネが見えない / 動画の web 用エンコードが無い」状態になる。**Immich の管理画面からジョブを走らせて再生成** する。

| ジョブ | 元データから再生成するもの | 必要度 |
|---|---|---|
| Library Scan | DB と FS の整合性確認・新規ファイル取り込み | ★★（最初に 1 回） |
| Thumbnail Generation | `thumbs/` のサムネイル + プレビュー | **★★★（必須、無いと UI が全部欠ける）** |
| Metadata Extraction | EXIF / 撮影日時 | ★★ |
| Video Transcoding | `encoded-video/` の web 再生用 H.264 等 | ★★（無くても原本再生はできる） |
| Face Detection | 顔の bounding box 検出 | ★★（人物機能使うなら） |
| Facial Recognition | 検出済み顔のクラスタリング | ★★（Face Detection の後） |
| Smart Search | CLIP embedding（自然言語検索用） | ★（一番重い、最後で OK） |

**手順（Web UI）**：

1. 管理者でログイン → ハンバーガー → **管理 (Administration)** → **ジョブ (Jobs)**
2. 上の順序で各ジョブをキック
   - **Thumbnail Generation だけ「すべて (All)」** で実行（既存のサムネが復元データに無いため）
   - それ以外は **「不足分のみ (Missing)」** で OK（DB に残っているメタデータ等は再計算不要）

**手順（API、CLI 一括）**：

```bash
IMMICH_HOST="http://localhost:2283"
API_KEY="your-admin-api-key"   # Immich の admin ユーザー設定で発行

# missing のみ実行 (force=false)
for job in library thumbnailGeneration metadataExtraction videoConversion \
           faceDetection facialRecognition smartSearch; do
    curl -X PUT "$IMMICH_HOST/api/jobs/$job" \
        -H "x-api-key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"command":"start","force":false}'
    echo " $job started"
done
```

**所要時間の目安**（500 GB 規模）：

| ジョブ | 時間 |
|---|---|
| Thumbnail Generation | 数時間〜半日 |
| Metadata Extraction | 数十分〜数時間 |
| Video Transcoding | 半日〜数日（4K 動画多いと最重） |
| Face Detection / Recognition | 数時間（GPU あれば速い） |
| Smart Search (CLIP) | 数時間〜半日（GPU あれば速い） |

CPU が忙しいなら Immich の管理画面で **Job Concurrency** を絞って並列度調整。

`backups/` は何もしなくても OK（Immich が定期的に自分で DB ダンプを書く）。

## 復元ドリル（半年〜年 1 回推奨）

「**バックアップが取れている**」と「**リストアが成功する**」は別物。S3 上のチャンクが本当に解凍可能なメディア + DB ダンプとして完成しているかを、**実際に別ディレクトリへ展開して live と照合する**作業が復元ドリル。

### コスト・時間・影響

| 項目 | 値 |
|---|---|
| AWS 費用（500 GB 規模） | **約 $36**（Bulk retrieval $1 + egress $35） |
| 時間 | 取り出し待ち 48h + ダウンロード 数時間 + 検証 1〜2h |
| live への影響 | **無し**（`/mnt/hdd1` も S3 バックアップも変更しない） |
| 必要なディスク空き | 復元先 + 展開ステージング = **約 800 GB** |

### Phase 1: 差分チェーンを作る（フル直後で差分がまだ無い場合）

ドリル本番でフル + 差分の連鎖を検証するため、事前に差分を 1〜2 回回しておく。

#### 1-a. cron を一時停止（時間が被ると面倒なので）

```bash
sudo crontab -u immich -l | sudo tee /tmp/immich-cron.bak > /dev/null
sudo crontab -u immich -r
```

#### 1-b. live ファイルの mtime を更新（差分に乗せる対象を作る）

```bash
# 適当な既存ファイルを 1〜2 個 touch（中身は変えず mtime だけ更新）
sudo -u immich touch /mnt/hdd1/library/<some-existing-file>
```

該当ファイルが何なのか後で照合するので、**フルパスをメモ**しておく。

#### 1-c. 1 回目の差分

```bash
tmux new -s immich-incr
sudo -u immich -H /opt/immich-backup-s3/scripts/backup_incremental.sh
# Slack に SUCCESS を確認 → Ctrl+b → d でデタッチ
```

S3 に `incremental/<TIMESTAMP_INC1>/` が作られる。`TIMESTAMP_INC1` を控える。

#### 1-d. もう 1 ファイル touch して 2 回目の差分

```bash
sudo -u immich touch /mnt/hdd1/library/<another-file>
sudo -u immich -H /opt/immich-backup-s3/scripts/backup_incremental.sh
```

`TIMESTAMP_INC2` を控える。

### Phase 2: S3 上の構造サニティ（無料の事前チェック）

```bash
# 管理マシン側 (admin AWS creds 使用)
# 順序が重要: 先に source で S3_BUCKET 等を取り込んでから AWS_PROFILE を unset。
# 逆だと .env の export で AWS_PROFILE=immich-backup が再設定されてしまう。
source /home/tutti/repos/immich-backup-s3/.env
unset AWS_PROFILE

aws s3 ls "s3://$S3_BUCKET/full/"
aws s3 ls "s3://$S3_BUCKET/incremental/"

# 各 manifest の中身を確認（Standard クラスなので即読める）
for kind in full incremental; do
    for prefix in $(aws s3 ls "s3://$S3_BUCKET/$kind/" | awk '{print $2}'); do
        [[ -z "$prefix" ]] && continue
        echo "=== $kind/$prefix ==="
        aws s3 cp "s3://$S3_BUCKET/$kind/${prefix}manifest.json" -
        echo
    done
done
```

各 manifest の `parts` 数 と、対応 prefix のオブジェクト数 - 1（manifest を除く）が一致することを確認。

### Phase 3: 取り出しリクエスト（Bulk = 48h 待ち）

直近フル + その後の差分すべての timestamp を控えて、Glacier Deep Archive から取り出しを依頼：

```bash
# Immich サーバー側
FULL=20260509T130000Z              # ←直近フルのタイムスタンプ
INC1=20260509T180000Z              # ←Phase 1-c のタイムスタンプ
INC2=20260509T200000Z              # ←Phase 1-d のタイムスタンプ

sudo -u immich -H bash -c "
    source /opt/immich-backup-s3/.env
    RETRIEVAL_TIER=Bulk \
    /opt/immich-backup-s3/scripts/restore.sh request '$FULL' '$INC1' '$INC2'
"
```

`Bulk`（$0.0025/GB、48h 待ち）と `Standard`（$0.02/GB、12h 待ち）が選択可。年 1 回のドリルなら Bulk で十分。

### Phase 4: 取り出し完了の確認

48h 経過後、各オブジェクトが取り出し済になっているか確認（管理マシン側、新シェルでも自己完結するよう source も含む）：

```bash
source /home/tutti/repos/immich-backup-s3/.env
unset AWS_PROFILE   # .env の AWS_PROFILE は runtime 用なので bootstrap/admin では消す

aws s3api head-object --bucket "$S3_BUCKET" \
    --key "full/$FULL/part_000" \
    --query 'Restore' --output text
# → "ongoing-request=\"false\", expiry-date=\"...\""
#    ongoing-request が "false" になっていれば取り出し完了
```

全パーツについてループで確認したいなら：

```bash
for key in $(aws s3 ls "s3://$S3_BUCKET/full/$FULL/" | awk '{print $4}'); do
    [[ -z "$key" ]] && continue
    [[ "$key" == "manifest.json" ]] && continue
    state=$(aws s3api head-object --bucket "$S3_BUCKET" \
        --key "full/$FULL/$key" --query 'Restore' --output text)
    echo "$key: $state"
done
```

すべて `ongoing-request="false"` なら次へ進む。

### Phase 5: ダウンロード + 展開

復元先の専用ディレクトリを準備（live を絶対に汚染しないよう、`/mnt/hdd1` 以外の場所を強く推奨）：

```bash
# /mnt/hdd1 配下のサブディレクトリでも、別マウントのディスクでも、空き 800 GB あれば
# どこでも OK。下の例は同じ HDD の /mnt/hdd1 配下に drill_target / drill_staging を
# 作る形 (Immich live は /mnt/hdd1/{library,upload,profile,...} に並ぶので干渉しない)。
# 別物理デバイスを使うなら例: /mnt/hdd2_drill_target, /mnt/ssd_drill_staging など。
sudo install -d -o immich -g immich -m 0755 \
    /mnt/hdd1/drill_target /mnt/hdd1/drill_staging
```

tmux で展開（数時間かかる）：

```bash
tmux new -s immich-drill
sudo -u immich -H bash -c "
    source /opt/immich-backup-s3/.env
    RESTORE_DIR=/mnt/hdd1/drill_staging \
    TARGET_DIR=/mnt/hdd1/drill_target \
    /opt/immich-backup-s3/scripts/restore.sh extract '$FULL' '$INC1' '$INC2'
"
# Ctrl+b → d でデタッチして気長に待つ
```

完了後の予想構造：

```
/mnt/hdd1/drill_target/
├── library/
├── upload/
├── profile/
├── db_<TIMESTAMP_INC2>.sql   ← 最新の差分の DB ダンプ（最新状態）
├── db_<TIMESTAMP_INC1>.sql   ← 差分1 時点の DB ダンプ（古い、上書きされず併存）
├── db_<TIMESTAMP_FULL>.sql   ← フル時点の DB ダンプ
├── docker-compose.yml
└── .env
```

### Phase 6: 検証

#### 6-a. ファイル数とサイズ比較

```bash
# 復元先
echo "=== restored ==="
sudo find /mnt/hdd1/drill_target -type f | wc -l
sudo du -sh /mnt/hdd1/drill_target

# live (除外を反映)
echo "=== live (in-scope only) ==="
sudo find /mnt/hdd1 \
    -path /mnt/hdd1/thumbs -prune -o \
    -path /mnt/hdd1/encoded-video -prune -o \
    -path /mnt/hdd1/backups -prune -o \
    -path /mnt/hdd1/.backup_tmp -prune -o \
    -path /mnt/hdd1/.backup_state -prune -o \
    -type f -print | wc -l
sudo du -sb --exclude=thumbs --exclude=encoded-video --exclude=backups \
    --exclude=.backup_tmp --exclude=.backup_state /mnt/hdd1 | numfmt --to=iec
```

両者がほぼ一致するはず（Phase 1 で touch したファイルが live にだけある分、復元先には DB ダンプ + config が余分にある分で多少ずれる）。

#### 6-b. Phase 1 で touch したファイルが正しく差分に乗っていたか

> 注意：`/mnt/hdd1/library` や `upload` は Immich が `drwx------ immich immich` で
> 作るため、admin ではないユーザーから `[[ -f ]]` で stat してもファイル不在
> 扱いになる。**ループ全体を `sudo bash -c` でくるんで root として実行する**こと。

```bash
# Phase 1-b と 1-d で touch したファイルが復元先に存在するか
sudo ls -la /mnt/hdd1/drill_target/library/<file-from-1b>
sudo ls -la /mnt/hdd1/drill_target/library/<file-from-1d>

# sha256 が live と一致するか
sudo bash -c '
for f in /mnt/hdd1/drill_target/library/<file-from-1b> \
         /mnt/hdd1/drill_target/library/<file-from-1d>; do
    rel=${f#/mnt/hdd1/drill_target/}
    h1=$(sha256sum "$f"             | awk "{print \$1}")
    h2=$(sha256sum "/mnt/hdd1/$rel" | awk "{print \$1}")
    [[ "$h1" == "$h2" ]] && echo "OK:    $rel" || echo "MISMATCH: $rel"
done
'
```

両方 OK なら、差分の連鎖（フル → 差分1 → 差分2）が正しく重ね合わせられて最新状態が再構築されている証拠。

#### 6-c. ランダムサンプリングで内容比較

```bash
# 復元先からランダムに 10 ファイル選んで sha256 比較
# (6-b と同じ理由で sudo bash -c でループ全体を root 化)
sudo bash -c '
find /mnt/hdd1/drill_target/library -type f | shuf -n 10 | while read f; do
    rel=${f#/mnt/hdd1/drill_target/}
    live="/mnt/hdd1/$rel"
    if [[ -f "$live" ]]; then
        h1=$(sha256sum "$f"    | awk "{print \$1}")
        h2=$(sha256sum "$live" | awk "{print \$1}")
        [[ "$h1" == "$h2" ]] && echo "OK:          $rel" || echo "MISMATCH:    $rel"
    else
        echo "NOT-IN-LIVE: $rel"  # live で削除済 → 復元データには残る = 想定済の挙動
    fi
done
'
```

期待値：

- **`OK:`** が大半（10/10 が理想）
- **`MISMATCH:`** が **0 件**（1 件でもあれば要調査）
- **`NOT-IN-LIVE:`** は数件あっても OK（バックアップ後に Immich で削除されたファイル）

なお、`live` 側のファイル数 > `restored` 側のファイル数 になるのも正常（バックアップ取得後に追加されたファイルは復元データに無い）。逆（restored が多い）は孤児ファイルなので想定内（design.md 9.1 参照）。

#### 6-d. DB ダンプの構文確認

```bash
# drill_target は tar 展開で source 側の権限 (0700 immich) を継承していて
# tutti から listing できないことがある (glob 展開が失敗する)。
# sudo bash -c でループ全体を root 化するのが確実。
sudo bash -c '
LATEST_DUMP=$(ls -t /mnt/hdd1/drill_target/db_*.sql | head -1)
echo "Latest dump: $LATEST_DUMP"
echo ""
echo "=== head ==="
head -10 "$LATEST_DUMP"   # PostgreSQL ヘッダコメントが見える
echo ""
echo "=== tail ==="
tail -5 "$LATEST_DUMP"    # \connect postgres で終わっているか
echo ""
echo "size:  $(du -h "$LATEST_DUMP" | awk "{print \$1}")"
echo "lines: $(wc -l < "$LATEST_DUMP")"
'
```

実際に psql で投入して整合性まで確認したいなら、別 PostgreSQL コンテナを立てて流し込む（リソース余裕がある時のみ）。

#### 6-e. config ファイルの確認

```bash
sudo cat /mnt/hdd1/drill_target/docker-compose.yml | head
sudo cat /mnt/hdd1/drill_target/.env | head
# → Immich の本番 docker-compose の中身が見えるはず
```

### Phase 6+: Immich UI で実機検証（推奨・任意）

ファイル sha256 一致 + DB ダンプ構文 OK までで「データは取り戻せる」が確認できますが、**「Immich アプリとして使える状態か」** を最後の砦として検証したいなら、**live Immich を止めずに drill 用の Immich コンテナ群を別ポートで立てる** のが安全。

#### 6+a. Drill 用の docker-compose ディレクトリを作る

live の compose ディレクトリから **`postgres/` 配下を除外して** コピーする。
`postgres/` は live の PostgreSQL データファイル群（テーブルファイル、WAL 等）
で、drill 側では空 DB に S3 からの dump を流し込むので **不要**。むしろ
live の DB ファイルを drill 側にコピーしてしまうと、

- 数十 GB の無駄な disk 使用
- live postgres が書き込み中の途中状態をコピーすることになり、ファイルが
  inconsistent になる可能性
- I/O 競合で live Immich がアクセス重くなる

ので明示的に除外する。

```bash
# rsync で postgres/ を除外コピー (live は /home/tutti/immich-app/ の前提)
sudo rsync -a --exclude='postgres/' --exclude='postgres-*/' \
    /home/tutti/immich-app/ /home/tutti/immich-app-drill/
cd /home/tutti/immich-app-drill

# 確認: docker-compose.yml と .env は来ていて、postgres/ は無い状態
ls -la
# 期待: docker-compose.yml, .env, (その他 yml ファイルがあれば) のみ
```

> もし `cp -r` で既にコピーしてしまった場合は、`sudo rm -rf
> /home/tutti/immich-app-drill/postgres` で live 由来の DB データを削除して
> から続ける。

#### 6+b. .env を drill 用に書き換え

```bash
sudo $EDITOR /home/tutti/immich-app-drill/.env
```

最低限の変更：

```bash
# 元の .env から:
UPLOAD_LOCATION=/mnt/hdd1               # ←変更
DB_DATA_LOCATION=./postgres             # ←変更
# (他はそのまま)

# Drill 用に:
UPLOAD_LOCATION=/mnt/hdd1/drill_target
DB_DATA_LOCATION=./postgres-drill        # 新規空ディレクトリ。dumpを後で流し込む
```

#### 6+c. docker-compose.yml を drill 用に書き換え

衝突回避のため以下を変更：

- **container_name** を `*_drill` 系に置換（live と同名だと起動できない）
- **ports** を host 側だけ別ポートに（例: 2283 → **2284**）
- ML サービスは drill では不要なので止めるか削除（重い）

最小編集の例：

```bash
sudo sed -i \
    -e 's/container_name: immich_server/container_name: immich_server_drill/' \
    -e 's/container_name: immich_machine_learning/container_name: immich_machine_learning_drill/' \
    -e 's/container_name: immich_postgres/container_name: immich_postgres_drill/' \
    -e 's/container_name: immich_redis/container_name: immich_redis_drill/' \
    -e 's|2283:2283|2284:2283|' \
    /home/tutti/immich-app-drill/docker-compose.yml
```

ML を止めるなら、該当 service を `profiles: [disabled]` でコメントアウト相当に：

```bash
# 手で編集: immich-machine-learning service の前に profiles を入れる
#   profiles: ["never"]
# とすると profile 無指定で起動しなくなる
```

確認：

```bash
sudo grep -E 'container_name|2283|UPLOAD' /home/tutti/immich-app-drill/docker-compose.yml
```

#### 6+d. drill 用 Postgres データディレクトリを準備

```bash
sudo install -d -o immich -g immich -m 0755 /home/tutti/immich-app-drill/postgres-drill
```

#### 6+e. Drill Postgres を先行起動（**immich-server は起動しない！**）

> ⚠️ **重要**: `docker compose up -d` でいきなり全コンテナ起動すると、immich-server が空 DB に **migrations を自動実行して schema を作ってしまう**。その後 dump を流し込んでも `already exists` エラーが連発し、データは 1 件も入らない。
>
> 正しい順序は **「postgres だけ起動 → 空 DB を確実にしてから dump 投入 → 後で残りを起動」**。

```bash
cd /home/tutti/immich-app-drill

# Postgres と Redis だけ起動。immich-server / ML はまだ起動しない。
sudo docker compose -p immich-drill up -d database redis

# Postgres ready 待ち
sleep 10
sudo docker exec immich_postgres_drill pg_isready -U postgres
# → "/var/run/postgresql:5432 - accepting connections" が出れば OK
```

`-p immich-drill` でプロジェクト名（= 独立した bridge network）を分離。live 側 (`immich-app`) と完全に分離されたコンテナ群として起動。

#### 6+f. 復元した DB ダンプを drill Postgres に投入

`docker-entrypoint` が `POSTGRES_DB=immich` の指定で空 `immich` DB を自動作成しているが、`pg_dumpall` の dump も `CREATE DATABASE immich;` を含むので、**先に空 DB を DROP して衝突を避ける**：

```bash
# 1. 自動作成された空の immich DB を drop (これから dump の CREATE DATABASE で作り直す)
sudo docker exec immich_postgres_drill psql -U postgres -c 'DROP DATABASE IF EXISTS immich;'

# 2. dump を流し込む
# drill_target は tar 展開で 0700 immich を継承していて tutti から listing できないことがあるので
# ls / glob / docker exec / psql 全部を root として実行するよう sudo bash -c で囲う。
sudo bash -c '
LATEST_DUMP=$(ls -t /mnt/hdd1/drill_target/db_*.sql | head -1)
echo "Restoring: $LATEST_DUMP"
docker exec -i immich_postgres_drill psql -U postgres < "$LATEST_DUMP" 2>&1 | tail -20
'
```

成功時の典型的な末尾：

```
... 
ALTER DATABASE
... (CREATE TABLE / COPY / ALTER 系が大量に流れる)
You are now connected to database "postgres" as user "postgres".
SET
SET
```

`ERROR: role "postgres" already exists` は無害（postgres はデフォルト superuser なので元から存在）。それ以外の `already exists` / `multiple primary keys` / `FK violation` が **大量に出るなら投入失敗**。空 DB に対する流し込みになっていない（schema が事前に存在している）状態なので、6+e の immich-server が起動していないか確認＆postgres-drill を rm -rf してやり直し。

データが入ったか確認：

```bash
sudo docker exec immich_postgres_drill psql -U postgres -d immich -c '
SELECT
    (SELECT COUNT(*) FROM "user") AS users,
    (SELECT COUNT(*) FROM asset) AS assets,
    (SELECT COUNT(*) FROM album) AS albums
'
```

`assets` が live のファイル数に近い値（ドリル時点の差分まで反映した状態）で出れば成功。

#### 6+g. 残りのコンテナを起動

これで DB がそろったので immich-server / ML を起動：

```bash
sudo docker compose -p immich-drill up -d
# immich-server / ML が新規に起動、database / redis は既に動いているので no-op
```

数十秒待ってログ確認：

```bash
sudo docker logs immich_server_drill --tail 50
# → 起動エラーが無いか、microservices の起動メッセージが見えるか
```

#### 6+h. ブラウザで UI 検証

```
http://<immich-server-ip>:2284
```

確認項目：

- [ ] 起動して **ログインページ** が表示される
- [ ] **既存ユーザーの ID/パスワードでログインできる**（DB ダンプから復元された認証情報が使えること = DB 整合性 OK）
- [ ] タイムラインに **写真サムネイルが表示される**（ただし `thumbs/` を除外しているので、ジョブ未走行のタイミングでは黒抜けや「再生成中」の表示があるかも）
- [ ] 1〜2 枚クリックして **オリジナル画像がフルサイズで開く**（= UPLOAD_LOCATION の実体ファイルが読めている）
- [ ] アルバム・人物・タグなどメタデータも見える（= DB が機能している）
- [ ] サムネ未生成のものは Immich のジョブ画面（管理者 → ジョブ）から **「サムネイルを生成」「ビデオを変換」** をキックしてエラーなく走るか軽く確認

ここまで通れば、**「災害発生時に S3 バックアップだけから Immich を再構築できる」** が証明できたことになります。

#### 6+i. drill 環境を撤収

```bash
cd /home/tutti/immich-app-drill
sudo docker compose -p immich-drill down -v   # -v でコンテナ + ボリュームも削除
```

`-v` を付けないと匿名ボリュームが残るので注意。drill のためだけに作ったボリュームなので削除して問題なし。

念のため：

```bash
# drill のコンテナが残っていないか
sudo docker ps -a | grep drill   # 何も出ないはず

# drill の compose ディレクトリも削除
sudo rm -rf /home/tutti/immich-app-drill
```

### Phase 7: 後始末

```bash
# 復元先と staging を削除（S3 バックアップは絶対に消さない）
sudo rm -rf /mnt/hdd1/drill_target /mnt/hdd1/drill_staging

# cron を復元
sudo crontab -u immich /tmp/immich-cron.bak
sudo crontab -u immich -l   # 確認
sudo rm /tmp/immich-cron.bak

# ドリル実施日を記録
echo "$(date -I): restore drill PASS" \
    | sudo -u immich tee -a /home/immich/restore-drill.log
```

S3 上の取り出し結果（"ongoing-request=false" 状態）は `restore.sh request` で `--days 7` 指定済みなので、放置で 7 日後に自動的に Glacier に戻る。明示的な再凍結操作は不要。

### Phase 8: マーカー無事確認

ドリルの restore は marker ファイルに触らない設計なので、次回 cron 差分には影響なし。念のため：

```bash
sudo ls -la /mnt/hdd1/.backup_state/last_backup_time
# mtime が Phase 1 の最後の差分（INC2）の時刻と一致していれば OK
```

### 失敗パターンと対処

| 症状 | 原因 / 対処 |
|---|---|
| Phase 4 で `Restore` が `null` | `restore.sh request` 未実行か対象 key の指定漏れ。再リクエスト |
| Phase 4 で `ongoing-request="true"` のまま 48h+ | AWS の遅延。普通もう少し待てば終わる。Standard ($0.02/GB) に切り替えて再リクエストする手も |
| Phase 5 で `tar: Unexpected EOF` | チャンクの欠落 / ダウンロード破損。`/mnt/hdd1/drill_staging/` 配下のサイズが S3 上の sum と合うか確認 |
| Phase 6-a でファイル数がドリル前と全然違う | 差分の concat 解釈失敗。`tar -i` フラグが付いているか `restore.sh` を確認 |
| Phase 6-b で sha256 mismatch | 差分のファイル選別に問題。`find -newer` の判定がずれている可能性 |

検出されたら GitHub Issue にして調査。

## 月額コスト目安

詳細は `design.md` 6.5。500 GB 規模で **約 $0.85 / 月**。Lambda + EventBridge + LIST は AWS Free Tier の always-free 枠内で実質 $0。

## トラブルシュート

- `aws s3 ls` が `Unable to locate credentials` を返す → `aws_signing_helper` のパス、cert/key の権限、`.env` の ARN を確認
- 差分バックアップで `snapshot file missing` → 直前にフルが走っていない。`backup_full.sh` を先に
- Lambda が Slack に流れない → CloudWatch Logs `/aws/lambda/ImmichBackupMonitor` を確認
- Glacier Deep Archive 早期削除課金が出た → `cleanup_old_full.sh` が 180 日未満を削除している。`RETENTION_DAYS` を確認
