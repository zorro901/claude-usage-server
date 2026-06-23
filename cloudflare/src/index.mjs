function json(body, init = {}) {
  return new Response(JSON.stringify(body, null, 2), {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...(init.headers || {}),
    },
  });
}

function html(body, init = {}) {
  return new Response(body, {
    ...init,
    headers: {
      "content-type": "text/html; charset=utf-8",
      ...(init.headers || {}),
    },
  });
}

function bearerToken(request) {
  const header = request.headers.get("authorization") || "";
  const prefix = "Bearer ";
  return header.startsWith(prefix) ? header.slice(prefix.length) : "";
}

function basicAuthPassword(request) {
  const header = request.headers.get("authorization") || "";
  const prefix = "Basic ";
  if (!header.startsWith(prefix)) {
    return null;
  }
  try {
    const decoded = atob(header.slice(prefix.length));
    const separator = decoded.indexOf(":");
    if (separator < 0) {
      return null;
    }
    return decoded.slice(separator + 1);
  } catch {
    return null;
  }
}

function dashboardAuthHeaders() {
  return {
    "WWW-Authenticate": 'Basic realm="Claude Usage Dashboard", charset="UTF-8"',
  };
}

function requireDashboardAuth(request, env) {
  if (!env.DASHBOARD_PASSWORD) {
    return null;
  }
  const password = basicAuthPassword(request);
  if (password !== env.DASHBOARD_PASSWORD) {
    return new Response("Unauthorized", {
      status: 401,
      headers: dashboardAuthHeaders(),
    });
  }
  return null;
}

function toInt(value) {
  if (value === null || value === undefined || value === "") return null;
  const num = Number(value);
  return Number.isFinite(num) ? Math.trunc(num) : null;
}

function normalizeLabel(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function flattenRow(payload, kind, item) {
  const session = item?.session || {};
  const cost = item?.cost || {};
  const summary = item?.summary || {};
  const usage = item?.current_usage || {};

  const tokenSource = kind === "current_session" ? usage : summary;
  const payloadForStorage =
    kind === "current_session"
      ? {
          captured_at: payload?.captured_at || new Date().toISOString(),
          source: item?.source ?? kind,
          host: item?.host ?? null,
          host_label: item?.host_label ?? null,
          platform: item?.platform ?? null,
          user_label: item?.user ?? item?.user_label ?? null,
          session,
          cost: item?.cost ?? null,
          context_window: item?.context_window ?? null,
        }
      : {
          captured_at: payload?.captured_at || new Date().toISOString(),
          source: item?.source ?? kind,
          host: item?.host ?? null,
          host_label: item?.host_label ?? null,
          platform: item?.platform ?? null,
          user_label: item?.user ?? item?.user_label ?? null,
          summary,
        };

  return {
    id: crypto.randomUUID(),
    captured_at: payload?.captured_at || new Date().toISOString(),
    kind,
    host: item?.host ?? null,
    host_label: normalizeLabel(item?.host_label),
    platform: item?.platform ?? null,
    user_label: normalizeLabel(item?.user ?? item?.user_label),
    session_id: session.session_id ?? null,
    session_name: session.session_name ?? null,
    transcript_path: session.transcript_path ?? null,
    input_tokens: toInt(tokenSource.input_tokens),
    output_tokens: toInt(tokenSource.output_tokens),
    cache_creation_input_tokens: toInt(tokenSource.cache_creation_input_tokens),
    cache_read_input_tokens: toInt(tokenSource.cache_read_input_tokens),
    total_cost_usd: kind === "current_session" ? Number(cost.total_cost_usd ?? 0) : null,
    payload_json: JSON.stringify(payloadForStorage),
  };
}

function insertStatement() {
  return `
    INSERT INTO claude_usage_events (
      id,
      captured_at,
      kind,
      host,
      host_label,
      platform,
      user_label,
      session_id,
      session_name,
      transcript_path,
      input_tokens,
      output_tokens,
      cache_creation_input_tokens,
      cache_read_input_tokens,
      total_cost_usd,
      payload_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `;
}

function dashboardHtml() {
  return `<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Claude Usage Dashboard</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #020617;
      --panel: #0f172a;
      --panel-2: #111827;
      --text: #e5e7eb;
      --muted: #94a3b8;
      --border: rgba(148, 163, 184, 0.18);
    }
    body {
      margin: 0;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: linear-gradient(180deg, #020617 0%, #0f172a 100%);
      color: var(--text);
    }
    .wrap { max-width: 1200px; margin: 0 auto; padding: 32px 20px 48px; }
    h1 { margin: 0 0 8px; font-size: 28px; }
    .sub { color: var(--muted); margin-bottom: 24px; }
    .grid { display: grid; grid-template-columns: 1.5fr 1fr; gap: 16px; }
    .card {
      background: rgba(15, 23, 42, 0.92);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 16px;
      box-shadow: 0 20px 60px rgba(0,0,0,0.25);
    }
    .card h2 { margin: 0 0 12px; font-size: 18px; }
    .table { width: 100%; border-collapse: collapse; }
    .table th, .table td {
      border-bottom: 1px solid var(--border);
      padding: 10px 8px;
      text-align: left;
      font-size: 14px;
    }
    .table th { color: var(--muted); font-weight: 600; }
    canvas { width: 100% !important; height: 420px !important; }
    @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } canvas { height: 320px !important; } }
  </style>
</head>
<body>
  <div class="wrap">
    <h1>Claude Usage Dashboard</h1>
    <div class="sub">ユーザー別の日次使用量と最新の受信状況</div>
    <div class="grid">
      <div class="card">
        <h2>日次入力トークン</h2>
        <canvas id="usageChart"></canvas>
      </div>
      <div class="card">
        <h2>ユーザー別合計</h2>
        <table class="table" id="summaryTable">
          <thead>
            <tr>
              <th>User</th>
              <th>Host</th>
              <th>Input</th>
              <th>Output</th>
            </tr>
          </thead>
          <tbody></tbody>
        </table>
      </div>
    </div>
  </div>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js"></script>
  <script>
    async function loadData() {
      const res = await fetch('/api/usage/series?days=30');
      return res.json();
    }

    function buildDatasets(rows) {
      const days = [...new Set(rows.map((row) => row.day))];
      const users = [...new Set(rows.map((row) => row.user_label))];
      const colors = ['#38bdf8', '#a78bfa', '#34d399', '#f59e0b', '#fb7185', '#60a5fa'];

      const datasets = users.map((user, index) => {
        const color = colors[index % colors.length];
        return {
          label: user,
          data: days.map((day) => {
            const found = rows.find((row) => row.day === day && row.user_label === user);
            return found ? Number(found.input_tokens) : 0;
          }),
          backgroundColor: color,
          borderColor: color,
        };
      });

      return { days, datasets };
    }

    function renderSummary(rows) {
      const tbody = document.querySelector('#summaryTable tbody');
      tbody.innerHTML = rows.map((row) => (
        '<tr>' +
          '<td>' + row.user_label + '</td>' +
          '<td>' + row.host_label + '</td>' +
          '<td>' + row.input_tokens + '</td>' +
          '<td>' + row.output_tokens + '</td>' +
        '</tr>'
      )).join('');
    }

    async function main() {
      const payload = await loadData();
      const { days, datasets } = buildDatasets(payload.series);
      renderSummary(payload.summary);
      const ctx = document.getElementById('usageChart');
      new Chart(ctx, {
        type: 'bar',
        data: { labels: days, datasets },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { labels: { color: '#e5e7eb' } },
          },
          scales: {
            x: { stacked: true, ticks: { color: '#94a3b8' }, grid: { color: 'rgba(148, 163, 184, 0.1)' } },
            y: { stacked: true, ticks: { color: '#94a3b8' }, grid: { color: 'rgba(148, 163, 184, 0.1)' } },
          },
        },
      });
    }

    main().catch((err) => {
      document.body.innerHTML = '<pre style="color:#fca5a5;padding:24px;">' + err.stack + '</pre>';
    });
  </script>
</body>
</html>`;
}

async function persistUsage(env, payload) {
  const rows = [];
  if (payload?.current_session) {
    rows.push(flattenRow(payload, "current_session", payload.current_session));
  }
  if (payload?.transcript_summary) {
    rows.push(flattenRow(payload, "transcript_summary", payload.transcript_summary));
  }
  if (payload?.heartbeat) {
    rows.push(
      flattenRow(payload, "transcript_summary", {
        ...payload.heartbeat,
        source: "heartbeat",
        summary: {
          session_count: 0,
          input_tokens: 0,
          output_tokens: 0,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
        },
      })
    );
  }

  if (rows.length === 0) {
    return { inserted: 0, kinds: [] };
  }

  await env.DB.batch(
    rows.map((row) =>
      env.DB.prepare(insertStatement()).bind(
        row.id,
        row.captured_at,
        row.kind,
        row.host,
        row.host_label,
        row.platform,
        row.user_label,
        row.session_id,
        row.session_name,
        row.transcript_path,
        row.input_tokens,
        row.output_tokens,
        row.cache_creation_input_tokens,
        row.cache_read_input_tokens,
        row.total_cost_usd,
        row.payload_json
      )
    )
  );

  return { inserted: rows.length, kinds: rows.map((row) => row.kind) };
}

async function readSeries(env, days = 30) {
  const count = Math.max(1, Math.min(365, Number(days) || 30));
  const window = `-${count} days`;
  const series = await env.DB.prepare(
    `
      SELECT
        date(captured_at) AS day,
        COALESCE(user_label, 'unknown') AS user_label,
        SUM(COALESCE(input_tokens, 0)) AS input_tokens,
        SUM(COALESCE(output_tokens, 0)) AS output_tokens,
        SUM(COALESCE(cache_creation_input_tokens, 0)) AS cache_creation_input_tokens,
        SUM(COALESCE(cache_read_input_tokens, 0)) AS cache_read_input_tokens,
        SUM(COALESCE(total_cost_usd, 0)) AS total_cost_usd
      FROM claude_usage_events
      WHERE strftime('%s', captured_at) >= strftime('%s', 'now', ?)
      GROUP BY day, user_label
      ORDER BY day ASC, user_label ASC
    `
  ).bind(window).all();

  const summary = await env.DB.prepare(
    `
      SELECT
        COALESCE(user_label, 'unknown') AS user_label,
        COALESCE(host_label, 'unknown') AS host_label,
        MAX(captured_at) AS last_seen_at,
        SUM(COALESCE(input_tokens, 0)) AS input_tokens,
        SUM(COALESCE(output_tokens, 0)) AS output_tokens,
        SUM(COALESCE(cache_creation_input_tokens, 0)) AS cache_creation_input_tokens,
        SUM(COALESCE(cache_read_input_tokens, 0)) AS cache_read_input_tokens,
        SUM(COALESCE(total_cost_usd, 0)) AS total_cost_usd
      FROM claude_usage_events
      GROUP BY user_label, host_label
      ORDER BY last_seen_at DESC
    `
  ).all();

  return { series: series.results || [], summary: summary.results || [] };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      const auth = requireDashboardAuth(request, env);
      if (auth) {
        return auth;
      }
      return html(dashboardHtml());
    }

    if (request.method === "GET" && url.pathname === "/api/usage/series") {
      const auth = requireDashboardAuth(request, env);
      if (auth) {
        return auth;
      }
      const days = url.searchParams.get("days") || "30";
      return json(await readSeries(env, days));
    }

    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const expectedToken = env.INGEST_TOKEN || "";
    if (expectedToken) {
      const presented = bearerToken(request);
      if (presented !== expectedToken) {
        return new Response("Unauthorized", { status: 401 });
      }
    }

    let payload;
    try {
      payload = await request.json();
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    if (
      !payload?.current_session?.host_label &&
      !payload?.transcript_summary?.host_label &&
      !payload?.heartbeat?.host_label
    ) {
      return new Response("host_label is required", { status: 400 });
    }
    if (
      !payload?.current_session?.user_label &&
      !payload?.transcript_summary?.user_label &&
      !payload?.heartbeat?.user_label
    ) {
      return new Response("user_label is required", { status: 400 });
    }

    const result = await persistUsage(env, payload);
    return json({ ok: true, inserted: result.inserted, kinds: result.kinds });
  },
};
