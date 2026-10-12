// Claudometer check-in counter (TZ NFR-4).
//   POST /ping   {id, version, language, os}  from the app, once per UTC day per install
//   GET  /stats  HTML summary, GET /stats.json the same as JSON; HTTP Basic auth with the
//                STATS_KEY secret as the password (any user name)
// Stores one row per install per day and nothing else: no IP addresses, no headers.

const KEEP_DAYS = 90;

const valid = {
  id: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
  version: /^\d{1,3}\.\d{1,3}\.\d{1,3}$/,
  language: /^[a-z]{2}$/,
  os: /^\d{1,3}\.\d{1,3}(\.\d{1,3})?$/,
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/ping" && request.method === "POST") return ping(request, env);
    if (url.pathname === "/stats" || url.pathname === "/stats.json") {
      if (!authorized(request, env)) {
        return new Response("Sign in with any user name and the stats key.", {
          status: 401,
          headers: { "WWW-Authenticate": 'Basic realm="Claudometer stats", charset="UTF-8"' },
        });
      }
      const stats = await summary(env);
      return url.pathname === "/stats.json"
        ? Response.json(stats, { headers: { "Cache-Control": "no-store" } })
        : new Response(page(stats), { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
    }
    return new Response("Not found", { status: 404 });
  },

  async scheduled(_event, env) {
    await env.DB.prepare("DELETE FROM pings WHERE day < date('now', ?)").bind(`-${KEEP_DAYS} days`).run();
  },
};

async function ping(request, env) {
  const text = await request.text();
  if (text.length > 512) return new Response("Too large", { status: 413 });
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }
  for (const [key, pattern] of Object.entries(valid)) {
    if (typeof body[key] !== "string" || !pattern.test(body[key])) return new Response(`Bad ${key}`, { status: 400 });
  }
  await env.DB.prepare(
    `INSERT INTO pings (day, id, version, language, os) VALUES (date('now'), ?1, ?2, ?3, ?4)
     ON CONFLICT (day, id) DO UPDATE SET version = excluded.version, language = excluded.language, os = excluded.os`
  ).bind(body.id, body.version, body.language, body.os).run();
  return new Response(null, { status: 204 });
}

function authorized(request, env) {
  const header = request.headers.get("Authorization") || "";
  if (!env.STATS_KEY || !header.startsWith("Basic ")) return false;
  let password;
  try {
    password = atob(header.slice(6)).split(":").slice(1).join(":");
  } catch {
    return false;
  }
  // Length check first, then a comparison that doesn't stop at the first difference.
  const a = new TextEncoder().encode(password);
  const b = new TextEncoder().encode(env.STATS_KEY);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function summary(env) {
  const one = (sql, ...args) => env.DB.prepare(sql).bind(...args).first("n");
  const all = async (sql, ...args) => (await env.DB.prepare(sql).bind(...args).all()).results;
  // Each install's latest row in the last 7 days, for the breakdowns.
  const latest = (field) => all(
    `SELECT ${field} AS label, COUNT(*) AS n FROM (
       SELECT ${field}, ROW_NUMBER() OVER (PARTITION BY id ORDER BY day DESC) AS rn
       FROM pings WHERE day > date('now', '-7 days')
     ) WHERE rn = 1 GROUP BY label ORDER BY n DESC`
  );
  const [today, week, month, total, daily, fresh, versions, languages, os] = await Promise.all([
    one("SELECT COUNT(*) AS n FROM pings WHERE day = date('now')"),
    one("SELECT COUNT(DISTINCT id) AS n FROM pings WHERE day > date('now', '-7 days')"),
    one("SELECT COUNT(DISTINCT id) AS n FROM pings WHERE day > date('now', '-30 days')"),
    one("SELECT COUNT(DISTINCT id) AS n FROM pings"),
    all("SELECT day, COUNT(*) AS n FROM pings WHERE day > date('now', '-30 days') GROUP BY day ORDER BY day"),
    all(`SELECT first AS day, COUNT(*) AS n FROM (SELECT id, MIN(day) AS first FROM pings GROUP BY id)
         WHERE first > date('now', '-30 days') GROUP BY first ORDER BY first`),
    latest("version"),
    latest("language"),
    latest("os"),
  ]);
  return { today, week, month, total, keepDays: KEEP_DAYS, daily, new: fresh, versions, languages, os };
}

function page(s) {
  const esc = (v) => String(v).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  // Last 30 days, oldest first, with empty days filled in.
  const days = [];
  for (let i = 29; i >= 0; i--) days.push(new Date(Date.now() - i * 86400000).toISOString().slice(0, 10));
  const active = Object.fromEntries(s.daily.map((r) => [r.day, r.n]));
  const added = Object.fromEntries(s.new.map((r) => [r.day, r.n]));
  const max = Math.max(1, ...days.map((d) => active[d] || 0));
  const bars = days.map((d) => {
    const n = active[d] || 0, k = added[d] || 0;
    return `<div class="bar" title="${d}: ${n} active, ${k} new"><span style="height:${(n / max) * 100}%"><i style="height:${n ? (k / n) * 100 : 0}%"></i></span></div>`;
  }).join("");
  const table = (title, rows) => {
    const sum = rows.reduce((a, r) => a + r.n, 0) || 1;
    const body = rows.length
      ? rows.map((r) => `<tr><td>${esc(r.label)}</td><td>${r.n}</td><td><b style="width:${(r.n / sum) * 100}%"></b></td></tr>`).join("")
      : `<tr><td colspan="3" class="muted">No data yet</td></tr>`;
    return `<section><h2>${title}</h2><table>${body}</table></section>`;
  };
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claudometer Stats</title><style>
:root{--bg:#f6f4f1;--card:#fff;--ink:#1d1b19;--muted:#77716b;--line:#e7e2dc;--accent:#d97757;--accent2:#f0b49c}
@media (prefers-color-scheme:dark){:root{--bg:#1b1a19;--card:#252321;--ink:#f1eee9;--muted:#9c958d;--line:#36332f;--accent:#e08a6c;--accent2:#7a4636}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:860px;margin:0 auto;padding:28px 16px 48px}h1{font-size:22px;margin:0 0 4px}p.muted,.muted{color:var(--muted)}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:22px 0}
.kpi,section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px}
.kpi b{display:block;font-size:30px;font-variant-numeric:tabular-nums}.kpi span{color:var(--muted);font-size:13px}
h2{font-size:14px;margin:0 0 12px;color:var(--muted);font-weight:600}
.chart{display:flex;align-items:flex-end;gap:3px;height:140px}.bar{flex:1;height:100%;display:flex;align-items:flex-end}
.bar span{width:100%;background:var(--accent);border-radius:4px 4px 1px 1px;display:flex;align-items:flex-end;min-height:2px;overflow:hidden}
.bar i{width:100%;background:var(--accent2)}.legend{display:flex;justify-content:space-between;font-size:12px;color:var(--muted);margin-top:6px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;margin-top:12px}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}td{padding:5px 0;border-top:1px solid var(--line)}tr:first-child td{border-top:0}
td:nth-child(2){text-align:right;padding:0 10px;width:1%}td:last-child{width:40%}td b{display:block;height:6px;border-radius:3px;background:var(--accent)}
</style></head><body><main>
<h1>Claudometer</h1><p class="muted">Anonymous daily check-ins. Data kept ${s.keepDays} days. Days are UTC.</p>
<div class="kpis">
<div class="kpi"><b>${s.today}</b><span>Active today</span></div>
<div class="kpi"><b>${s.week}</b><span>Active, last 7 days</span></div>
<div class="kpi"><b>${s.month}</b><span>Active, last 30 days</span></div>
<div class="kpi"><b>${s.total}</b><span>Installs seen, last ${s.keepDays} days</span></div>
</div>
<section><h2>Active per day (lighter: new installs)</h2><div class="chart">${bars}</div>
<div class="legend"><span>${days[0]}</span><span>${days[29]}</span></div></section>
<div class="grid">${table("Version (last 7 days)", s.versions)}${table("Language", s.languages)}${table("macOS", s.os)}</div>
</main></body></html>`;
}
