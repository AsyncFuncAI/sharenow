const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: JSON_HEADERS });
}

function bearer(request) {
  const value = request.headers.get("authorization") || "";
  return value.startsWith("Bearer ") ? value.slice(7) : "";
}

async function tokenHash(token) {
  const bytes = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function actor(request, env) {
  const token = bearer(request);
  if (!token) return null;
  if (token === env.APP_ADMIN_TOKEN) return { label: "Owner", role: "admin" };
  const hash = await tokenHash(token);
  return env.DB.prepare("SELECT label, role FROM team_members WHERE token_hash = ?").bind(hash).first();
}

function canWrite(member) {
  return member && (member.role === "admin" || member.role === "operator");
}

function id(prefix) {
  return `${prefix}_${crypto.randomUUID().replaceAll("-", "").slice(0, 20)}`;
}

async function parseJson(request) {
  try { return await request.json(); } catch { return null; }
}

async function intakeAllowed(request, env) {
  const source = request.headers.get("cf-connecting-ip") || "unknown";
  const day = new Date().toISOString().slice(0, 10);
  const key = await tokenHash(`${day}:${source}`);
  const row = await env.DB.prepare("INSERT INTO intake_rate_limits (key, count, updated_at) VALUES (?, 1, ?) ON CONFLICT(key) DO UPDATE SET count = count + 1, updated_at = excluded.updated_at RETURNING count")
    .bind(key, new Date().toISOString()).first();
  return Number(row?.count || 0) <= 20;
}

async function intake(request, env) {
  const body = await parseJson(request);
  if (body?.website) return json({ status: "queued" }, 202);
  if (!body || typeof body.email !== "string" || typeof body.name !== "string") {
    return json({ error: "name and email are required" }, 400);
  }
  const email = body.email.trim().toLowerCase();
  const name = body.name.trim();
  if (!name || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return json({ error: "a valid name and email are required" }, 400);
  }
  if (!(await intakeAllowed(request, env))) return json({ error: "daily intake limit reached" }, 429);
  const leadId = id("lead");
  const now = new Date().toISOString();
  await env.DB.prepare("INSERT INTO leads (id, email, name, company, status, created_at, updated_at) VALUES (?, ?, ?, ?, 'queued', ?, ?)")
    .bind(leadId, email.slice(0, 254), name.slice(0, 120), String(body.company || "").slice(0, 160), now, now).run();
  await env.ENRICHMENT_QUEUE.send({ leadId, source: "intake" });
  return json({ leadId, status: "queued" }, 202);
}

async function invite(request, env, member) {
  if (!member || member.role !== "admin") return json({ error: "admin required" }, 403);
  const body = await parseJson(request);
  const role = body?.role === "operator" ? "operator" : "reviewer";
  const label = typeof body?.label === "string" ? body.label.slice(0, 80) : "Teammate";
  const token = `loop_${crypto.randomUUID().replaceAll("-", "")}`;
  await env.DB.prepare("INSERT INTO team_members (token_hash, label, role, created_at) VALUES (?, ?, ?, ?)")
    .bind(await tokenHash(token), label, role, new Date().toISOString()).run();
  return json({ token, label, role, note: "This token is shown once." }, 201);
}

async function callClaude(lead, env) {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": env.ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: env.ANTHROPIC_MODEL,
      max_tokens: 220,
      messages: [{
        role: "user",
        content: `Qualify this inbound lead. Return strict JSON with integer score 0-100 and a short summary. Name: ${lead.name}. Company: ${lead.company}. Email domain: ${lead.email.split("@")[1] || "unknown"}.`,
      }],
    }),
  });
  if (!response.ok) throw new Error(`model request failed (${response.status})`);
  const payload = await response.json();
  const text = payload?.content?.find((part) => part.type === "text")?.text || "";
  const match = text.match(/\{[\s\S]*\}/);
  if (!match) throw new Error("model returned no JSON object");
  const result = JSON.parse(match[0]);
  return {
    score: Math.max(0, Math.min(100, Number(result.score) || 0)),
    summary: String(result.summary || "No summary returned").slice(0, 800),
  };
}

async function enrichLead(leadId, source, env) {
  const claimedAt = new Date().toISOString();
  const claim = await env.DB.prepare("UPDATE leads SET status = 'processing', attempts = attempts + 1, updated_at = ? WHERE id = ? AND status IN ('queued', 'retry') AND attempts < 3")
    .bind(claimedAt, leadId).run();
  if (Number(claim?.meta?.changes || 0) === 0) return "done";
  const lead = await env.DB.prepare("SELECT * FROM leads WHERE id = ?").bind(leadId).first();
  if (!lead) return "done";
  const runId = id("run");
  const started = claimedAt;
  await env.DB.prepare("INSERT INTO loop_runs (id, lead_id, source, status, started_at) VALUES (?, ?, ?, 'running', ?)")
    .bind(runId, leadId, source, started).run();
  try {
    const result = await callClaude(lead, env);
    const finished = new Date().toISOString();
    await env.DB.prepare("UPDATE leads SET status = 'ready', score = ?, summary = ?, updated_at = ? WHERE id = ?")
      .bind(result.score, result.summary, finished, leadId).run();
    await env.DB.prepare("UPDATE loop_runs SET status = 'complete', detail = ?, finished_at = ? WHERE id = ?")
      .bind(result.summary, finished, runId).run();
    await env.REPORTS.put(`runs/${runId}.json`, JSON.stringify({ runId, leadId, source, result, finished }));
    return "done";
  } catch (error) {
    const finished = new Date().toISOString();
    const detail = error instanceof Error ? error.message.slice(0, 500) : "unknown loop error";
    const exhausted = Number(lead.attempts || 0) >= 3;
    await env.DB.prepare("UPDATE leads SET status = ?, updated_at = ? WHERE id = ?")
      .bind(exhausted ? "failed" : "retry", finished, leadId).run();
    await env.DB.prepare("UPDATE loop_runs SET status = 'failed', detail = ?, finished_at = ? WHERE id = ?")
      .bind(detail, finished, runId).run();
    return exhausted ? "done" : "retry";
  }
}

const HOME = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Loopdesk</title><style>body{font:16px system-ui;max-width:720px;margin:8vh auto;padding:24px;color:#17211b;background:#f4f7f2}main{background:white;border:1px solid #ced8cf;padding:32px}input,button{font:inherit;padding:12px;margin:6px 0;width:100%;box-sizing:border-box}button{background:#173d2a;color:white;border:0;cursor:pointer}.note{color:#607067}.trap{position:absolute;left:-10000px}</style></head><body><main><p class="note">LOOPDESK · LIVE AGENT LOOP</p><h1>Send a lead into the loop.</h1><p>Queue it now. Claude qualifies it in the background, sharenow keeps the state and report.</p><form id="f"><input name="name" placeholder="Name" required><input name="email" type="email" placeholder="Email" required><input name="company" placeholder="Company"><label class="trap" aria-hidden="true">Website<input name="website" tabindex="-1" autocomplete="off"></label><button>Queue lead</button></form><pre id="out"></pre></main><script>f.onsubmit=async(e)=>{e.preventDefault();const b=Object.fromEntries(new FormData(f));const r=await fetch('/api/intake',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)});out.textContent=JSON.stringify(await r.json(),null,2)}</script></body></html>`;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/") return new Response(HOME, { headers: { "content-type": "text/html; charset=utf-8" } });
    if (request.method === "POST" && url.pathname === "/api/intake") return intake(request, env);
    const member = await actor(request, env);
    if (!member) return json({ error: "valid team token required" }, 401);
    if (request.method === "GET" && url.pathname === "/api/leads") {
      const rows = await env.DB.prepare("SELECT * FROM leads ORDER BY created_at DESC LIMIT 100").all();
      return json({ actor: member, leads: rows.results || [] });
    }
    if (request.method === "GET" && url.pathname === "/api/runs") {
      const rows = await env.DB.prepare("SELECT * FROM loop_runs ORDER BY started_at DESC LIMIT 100").all();
      return json({ actor: member, runs: rows.results || [] });
    }
    if (request.method === "POST" && url.pathname === "/api/team/invites") return invite(request, env, member);
    if (request.method === "POST" && url.pathname.startsWith("/api/retry/")) {
      if (!canWrite(member)) return json({ error: "operator required" }, 403);
      const leadId = url.pathname.slice("/api/retry/".length);
      await env.ENRICHMENT_QUEUE.send({ leadId, source: "manual-retry" });
      return json({ leadId, status: "queued" }, 202);
    }
    return json({ error: "not found" }, 404);
  },

  async queue(batch, env) {
    for (const message of batch.messages) {
      const outcome = await enrichLead(message.body.leadId, message.body.source || "queue", env);
      if (outcome === "retry") message.retry();
      else message.ack();
    }
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil((async () => {
      const pending = await env.DB.prepare("SELECT id FROM leads WHERE status IN ('queued', 'retry') AND attempts < 3 ORDER BY updated_at LIMIT 25").all();
      for (const lead of pending.results || []) await env.ENRICHMENT_QUEUE.send({ leadId: lead.id, source: "scheduled-reconcile" });
    })());
  },
};
