#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  claude-usage-report.sh [--scan-transcripts]

Environment:
  CLAUDE_USAGE_INGEST_URL       Optional ingest URL to POST JSON to.
  CLAUDE_USAGE_INGEST_TOKEN      Optional bearer token sent as Authorization when posting.
  CLAUDE_USAGE_SCAN_TRANSCRIPTS  Set to 1 to scan ~/.claude/projects for completed sessions.
  CLAUDE_HOME                    Override the Claude home directory (defaults to ~/.claude).
  CLAUDE_USAGE_STATE_DIR         Directory used to persist transcript scan state.
  CLAUDE_USAGE_HOST_LABEL        Required stable host label to report.
  CLAUDE_USAGE_USER_LABEL        Required stable user label to report.

Input:
  If JSON is piped on stdin, the script captures the current session snapshot.
  If transcript scanning is enabled, it also summarizes the latest usage from each
  .jsonl transcript it finds.
EOF
}

scan_transcripts=0
if [[ "${1:-}" == "--scan-transcripts" ]]; then
  scan_transcripts=1
  shift
fi

if [[ $# -gt 0 ]]; then
  usage >&2
  exit 2
fi

if [[ "${CLAUDE_USAGE_SCAN_TRANSCRIPTS:-0}" == "1" ]]; then
  scan_transcripts=1
fi

claude_home="${CLAUDE_HOME:-$HOME/.claude}"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hostname_short="$(hostname -s 2>/dev/null || hostname)"
host_label="${CLAUDE_USAGE_HOST_LABEL:-}"
current_user="${CLAUDE_USAGE_USER_LABEL:-}"
platform="$(uname -srm 2>/dev/null || echo unknown)"

if [[ -z "$host_label" ]]; then
  echo "CLAUDE_USAGE_HOST_LABEL is required" >&2
  exit 1
fi

if [[ -z "$current_user" ]]; then
  echo "CLAUDE_USAGE_USER_LABEL is required" >&2
  exit 1
fi

stdin_json=""
if [[ ! -t 0 ]]; then
  stdin_json="$(cat)"
  if [[ -z "$stdin_json" ]]; then
    stdin_json=""
  fi
fi

current_payload=""
if [[ -n "$stdin_json" ]]; then
  current_payload="$(
    jq -c \
      --arg captured_at "$timestamp" \
      --arg host "$hostname_short" \
      --arg host_label "$host_label" \
      --arg platform "$platform" \
      --arg user "$current_user" '
      {
        captured_at: $captured_at,
        source: "stdin",
        host: $host,
        host_label: $host_label,
        platform: $platform,
        user: $user,
        user_label: $user,
        session: {
          session_id: .session_id,
          session_name: .session_name,
          transcript_path: .transcript_path,
          version: .version
        },
        workspace: {
          current_dir: .workspace.current_dir,
          project_dir: .workspace.project_dir,
          added_dirs: .workspace.added_dirs,
          repo: .workspace.repo,
          git_worktree: .workspace.git_worktree
        },
        cost: .cost,
        context_window: .context_window,
        rate_limits: .rate_limits,
        output_style: .output_style,
        vim: .vim,
        agent: .agent,
        pr: .pr,
        worktree: .worktree
      }
    ' <<<"$stdin_json"
    )"
fi

transcript_payload=""
heartbeat_payload=""
if [[ "$scan_transcripts" == "1" ]]; then
  transcript_dir="$claude_home/projects"
  state_dir="${CLAUDE_USAGE_STATE_DIR:-$HOME/.claude-usage-state}"
  state_file="$state_dir/transcript-state.json"
  if [[ -d "$transcript_dir" ]]; then
    mkdir -p "$state_dir"
    tmp_state_records="$(mktemp)"
    tmp_delta_sessions="$(mktemp)"
    trap 'rm -f "$tmp_state_records" "$tmp_delta_sessions"' EXIT

    state_json="{}"
    if [[ -f "$state_file" ]]; then
      state_json="$(cat "$state_file")"
    fi

    transcript_count="$(find "$transcript_dir" -type f -name '*.jsonl' -print0 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ')"

    while IFS= read -r -d '' file; do
      usage_json="$(
        jq -cs '
          def zero:
            {
              input_tokens: 0,
              output_tokens: 0,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0
            };
          def add_usage($u):
            .input_tokens += ($u.input_tokens // 0)
            | .output_tokens += ($u.output_tokens // 0)
            | .cache_creation_input_tokens += ($u.cache_creation_input_tokens // 0)
            | .cache_read_input_tokens += ($u.cache_read_input_tokens // 0);
          [ .[]
            | select(type == "object")
            | (.message.usage? // .usage? // empty)
          ]
          | if length > 0 then reduce .[] as $u (zero; add_usage($u)) else empty end
        ' "$file" 2>/dev/null || true
      )"

      if [[ -z "$usage_json" || "$usage_json" == "null" ]]; then
        continue
      fi

      jq -cn \
        --arg path "$file" \
        --argjson usage "$usage_json" \
        '{path: $path, usage: $usage}' >>"$tmp_state_records"

      prev_usage="$(
        jq -c --arg path "$file" '.[$path] // null' <<<"$state_json"
      )"

      delta_json="$(
        jq -cn \
          --argjson current "$usage_json" \
          --argjson prev "${prev_usage:-null}" '
          def num($v): ($v // 0 | tonumber);
          def delta($key): (num($current[$key]) - num($prev[$key]));
          {
            input_tokens: delta("input_tokens"),
            output_tokens: delta("output_tokens"),
            cache_creation_input_tokens: delta("cache_creation_input_tokens"),
            cache_read_input_tokens: delta("cache_read_input_tokens")
          }
          | if .input_tokens < 0 then .input_tokens = num($current.input_tokens) else . end
          | if .output_tokens < 0 then .output_tokens = num($current.output_tokens) else . end
          | if .cache_creation_input_tokens < 0 then .cache_creation_input_tokens = num($current.cache_creation_input_tokens) else . end
          | if .cache_read_input_tokens < 0 then .cache_read_input_tokens = num($current.cache_read_input_tokens) else . end
        '
      )"

      if jq -e '
        .input_tokens > 0 or
        .output_tokens > 0 or
        .cache_creation_input_tokens > 0 or
        .cache_read_input_tokens > 0
      ' <<<"$delta_json" >/dev/null; then
        session_id="$(basename "$file")"
        session_id="${session_id%.jsonl}"
        jq -cn \
          --arg session_id "$session_id" \
          --arg transcript_path "$file" \
          --argjson usage "$delta_json" \
          '{
            session_id: $session_id,
            transcript_path: $transcript_path,
            usage: $usage
          }' >>"$tmp_delta_sessions"
      fi
    done < <(find "$transcript_dir" -type f -name '*.jsonl' -print0 2>/dev/null)

    if [[ -s "$tmp_state_records" ]]; then
      state_json="$(
        jq -cs --argjson prev "$state_json" '
          reduce .[] as $r ($prev; .[$r.path] = $r.usage)
        ' "$tmp_state_records"
      )"
      printf '%s\n' "$state_json" >"$state_file"
    fi

    if [[ -s "$tmp_delta_sessions" ]]; then
      transcript_payload="$(
        jq -cs \
          --arg captured_at "$timestamp" \
          --arg host "$hostname_short" \
          --arg host_label "$host_label" \
          --arg platform "$platform" \
          --arg user "$current_user" '
          def num_or_zero($v): ($v // 0);
          {
            captured_at: $captured_at,
            source: "transcript_summary",
            host: $host,
            host_label: $host_label,
            platform: $platform,
            user: $user,
            user_label: $user,
            summary: (
              reduce .[] as $session (
                {
                  session_count: 0,
                  input_tokens: 0,
                  output_tokens: 0,
                  cache_creation_input_tokens: 0,
                  cache_read_input_tokens: 0
                };
                .session_count += 1
                | .input_tokens += num_or_zero($session.usage.input_tokens)
                | .output_tokens += num_or_zero($session.usage.output_tokens)
                | .cache_creation_input_tokens += num_or_zero($session.usage.cache_creation_input_tokens)
                | .cache_read_input_tokens += num_or_zero($session.usage.cache_read_input_tokens)
              )
            ),
            sessions: .
          }
        ' "$tmp_delta_sessions"
      )"
    else
      heartbeat_payload="$(
        jq -cn \
          --arg captured_at "$timestamp" \
          --arg host "$hostname_short" \
          --arg host_label "$host_label" \
          --arg platform "$platform" \
          --arg user "$current_user" \
          --argjson transcript_count "${transcript_count:-0}" '
          {
            captured_at: $captured_at,
            source: "heartbeat",
            host: $host,
            host_label: $host_label,
            platform: $platform,
            user: $user,
            user_label: $user,
            transcript_count: $transcript_count
          }
        '
      )"
    fi
  fi
fi

if [[ -z "$current_payload" && -z "$transcript_payload" && -z "$heartbeat_payload" ]]; then
  echo "No stdin JSON and no transcript data found." >&2
  exit 1
fi

payload="$(
  jq -cn \
    --argjson current "${current_payload:-null}" \
    --argjson transcripts "${transcript_payload:-null}" \
    --argjson heartbeat "${heartbeat_payload:-null}" \
    '{
      current_session: $current,
      transcript_summary: $transcripts,
      heartbeat: $heartbeat
    }'
)"

ingest_url="${CLAUDE_USAGE_INGEST_URL:-${CLAUDE_USAGE_WEBHOOK_URL:-}}"

if [[ -n "$ingest_url" ]]; then
  curl_args=(
    -fsS
    -X POST
    -H 'Content-Type: application/json'
    --data "$payload"
  )
  if [[ -n "${CLAUDE_USAGE_INGEST_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${CLAUDE_USAGE_INGEST_TOKEN}")
  fi
  curl "${curl_args[@]}" "$ingest_url" >/dev/null
else
  printf '%s\n' "$payload"
fi
