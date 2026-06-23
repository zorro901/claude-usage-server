# Claude Usage Report

Claude Code のセッション情報とトークン使用量を、シェル経由で集計・送信するための最小構成です。

## できること

- `stdin` に流れてくる Claude Code のセッション JSON を、そのまま 1 件のレポートとして送信
- `~/.claude/projects` 配下の `.jsonl` transcript をスキャンして、完了済みセッションを集計
- `CLAUDE_USAGE_INGEST_URL` があれば `POST`、なければ JSON を標準出力へ出力
- `host_label` と `user_label` を必須でレポートに含める
- transcript の差分送信状態は `CLAUDE_USAGE_STATE_DIR` に保存する
- Cloudflare Worker のダッシュボードでユーザー別の日次グラフを表示する

## スクリプト

- `scripts/claude-usage-report.sh`
- `scripts/deploy-cloudflare.sh`
- `Dockerfile`
- `compose.yaml`
- `cloudflare/`

## 使い方

### 1. 現在のセッション情報を送る

Claude Code の status line か hook から、このスクリプトへ JSON を渡します。

```bash
cat session.json | scripts/claude-usage-report.sh
```

### 2. transcript を定期集計する

```bash
CLAUDE_USAGE_SCAN_TRANSCRIPTS=1 \
CLAUDE_USAGE_INGEST_URL="https://example.com/webhook" \
scripts/claude-usage-report.sh
```

### 3. Docker で定期送信する

```bash
CLAUDE_USAGE_INGEST_URL="https://example.com/webhook" \
CLAUDE_USAGE_INGEST_TOKEN="secret" \
CLAUDE_USAGE_INTERVAL_SECONDS=300 \
docker compose -f compose.yaml up -d --build
```

この構成では、コンテナが `~/.claude` を読み取り専用で参照して、5 分ごとに transcript を集計して送信します。ホストごとの識別が必要なら `CLAUDE_USAGE_HOST_LABEL` を明示的に入れてください。
`CLAUDE_USAGE_HOST_LABEL` と `CLAUDE_USAGE_USER_LABEL` は必須です。未設定だとスクリプトは失敗します。
差分送信用の state は `~/.claude-usage-state` を永続 volume として保持します。
初回だけホスト側で `mkdir -p /Users/user/.claude-usage-state` を実行しておくと安全です。

### 4. Cloudflare D1 に入れる

`cloudflare/` に Worker と D1 用の定義を置いています。流れは次の通りです。

1. `scripts/deploy-cloudflare.sh` を実行して migration と deploy をまとめて行う
2. 必要なら `CLOUDFLARE_INGEST_TOKEN` を設定して Worker 側の `INGEST_TOKEN` を登録する
3. 必要なら `CLOUDFLARE_DASHBOARD_PASSWORD` を設定して Worker 側のダッシュボード認証を有効にする
4. Worker の URL を `CLAUDE_USAGE_INGEST_URL` に設定する

ダッシュボード認証を有効にした場合、ブラウザで `GET /` を開くと Basic Auth を求められます。ユーザー名は任意、パスワードは `DASHBOARD_PASSWORD` です。

このリポジトリでは D1 ID `f7853ec3-fee0-4823-992f-5162b5d4e15e` を前提にしています。
ダッシュボードは Worker の `GET /` で見られます。集計 JSON は `GET /api/usage/series?days=30` です。

`/schedule` は Claude Code の routine なので、クラウド上で実行されます。ローカルの `~/.claude/projects` を集計したい用途とは相性が悪いです。今回は Docker の定期送信と Cloudflare D1 の組み合わせのほうが目的に合っています。

## 依存

- `jq`
- `curl`（Webhook 送信する場合）
- Docker 実行時は `docker compose`
- Cloudflare Worker / D1 を使う場合は `wrangler`

## 出力例

```json
{
  "current_session": {
    "captured_at": "2026-06-23T00:00:00Z",
    "source": "stdin",
    "host": "mac-mini",
    "user": "user",
    "session": {
      "session_id": "abc123",
      "session_name": "refactor-usage",
      "transcript_path": "/Users/user/.claude/projects/.../abc123.jsonl",
      "version": "2.1.186"
    }
  },
  "transcript_summary": {
    "captured_at": "2026-06-23T00:00:00Z",
    "source": "transcripts",
    "summary": {
      "session_count": 12,
      "input_tokens": 123456,
      "output_tokens": 65432,
      "cache_creation_input_tokens": 1111,
      "cache_read_input_tokens": 2222
    }
  }
}
```
