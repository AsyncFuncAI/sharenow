import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = await readFile(new URL("../sharenow/templates/loop-crm/worker.js", import.meta.url), "utf8");
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

class FakeDb {
  constructor() {
    this.leads = new Map();
    this.runs = new Map();
    this.members = new Map();
    this.rateLimits = new Map();
  }

  prepare(sql) {
    const db = this;
    let values = [];
    return {
      bind(...next) { values = next; return this; },
      async run() {
        if (sql.startsWith("INSERT INTO leads")) {
          const [id, email, name, company, created, updated] = values;
          db.leads.set(id, { id, email, name, company, status: "queued", score: null, summary: null, attempts: 0, created_at: created, updated_at: updated });
        } else if (sql.startsWith("INSERT INTO loop_runs")) {
          const [id, leadId, source, started] = values;
          db.runs.set(id, { id, lead_id: leadId, source, status: "running", started_at: started });
        } else if (sql.startsWith("INSERT INTO team_members")) {
          const [hash, label, role, created] = values;
          db.members.set(hash, { label, role, created_at: created });
        } else if (sql.includes("UPDATE leads SET status = 'processing'")) {
          const [updated, id] = values;
          const lead = db.leads.get(id);
          if (!lead || !["queued", "retry"].includes(lead.status) || lead.attempts >= 3) {
            return { success: true, meta: { changes: 0 } };
          }
          Object.assign(lead, { status: "processing", updated_at: updated, attempts: lead.attempts + 1 });
          return { success: true, meta: { changes: 1 } };
        } else if (sql.includes("UPDATE leads SET status = 'ready'")) {
          const [score, summary, updated, id] = values;
          Object.assign(db.leads.get(id), { score, summary, status: "ready", updated_at: updated });
        } else if (sql.includes("UPDATE leads SET status = ?")) {
          const [status, updated, id] = values;
          Object.assign(db.leads.get(id), { status, updated_at: updated });
        } else if (sql.startsWith("UPDATE loop_runs")) {
          const [detail, finished, id] = values;
          Object.assign(db.runs.get(id), { detail, finished_at: finished, status: sql.includes("'complete'") ? "complete" : "failed" });
        }
        return { success: true };
      },
      async first() {
        if (sql.startsWith("INSERT INTO intake_rate_limits")) {
          const [key, updated] = values;
          const count = (db.rateLimits.get(key)?.count || 0) + 1;
          db.rateLimits.set(key, { count, updated_at: updated });
          return { count };
        }
        if (sql.startsWith("SELECT label, role FROM team_members")) return db.members.get(values[0]) || null;
        if (sql.startsWith("SELECT * FROM leads WHERE id")) return db.leads.get(values[0]) || null;
        return null;
      },
      async all() {
        if (sql.startsWith("SELECT * FROM leads")) return { results: [...db.leads.values()] };
        if (sql.startsWith("SELECT * FROM loop_runs")) return { results: [...db.runs.values()] };
        if (sql.startsWith("SELECT id FROM leads")) {
          return { results: [...db.leads.values()].filter((lead) => ["queued", "retry"].includes(lead.status) && lead.attempts < 3).map(({ id }) => ({ id })) };
        }
        return { results: [] };
      },
    };
  }
}

function environment() {
  const DB = new FakeDb();
  const sent = [];
  const reports = new Map();
  return {
    DB,
    sent,
    reports,
    env: {
      DB,
      APP_ADMIN_TOKEN: "admin-test-token",
      ANTHROPIC_API_KEY: "anthropic-test-key",
      ANTHROPIC_MODEL: "test-model",
      ENRICHMENT_QUEUE: { async send(message) { sent.push(message); } },
      REPORTS: { async put(key, value) { reports.set(key, value); } },
    },
  };
}

test("public intake queues a durable lead and admin can inspect it", async () => {
  const { env, DB, sent } = environment();
  const intake = await worker.fetch(new Request("https://app.test/api/intake", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name: "Jason", email: "jason@example.com", company: "Loop Co" }),
  }), env);
  assert.equal(intake.status, 202);
  const created = await intake.json();
  assert.equal(DB.leads.get(created.leadId).status, "queued");
  assert.deepEqual(sent, [{ leadId: created.leadId, source: "intake" }]);

  const denied = await worker.fetch(new Request("https://app.test/api/leads"), env);
  assert.equal(denied.status, 401);
  const listed = await worker.fetch(new Request("https://app.test/api/leads", {
    headers: { authorization: "Bearer admin-test-token" },
  }), env);
  assert.equal(listed.status, 200);
  assert.equal((await listed.json()).leads.length, 1);
});

test("queue loop calls the configured model, records state, and writes an R2 report", async () => {
  const { env, DB, reports } = environment();
  const leadId = "lead_test";
  DB.leads.set(leadId, { id: leadId, name: "Jason", email: "jason@example.com", company: "Loop Co", status: "queued", attempts: 0 });
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, options) => {
    assert.equal(options.headers["x-api-key"], "anthropic-test-key");
    assert.equal(JSON.parse(options.body).model, "test-model");
    return new Response(JSON.stringify({ content: [{ type: "text", text: '{"score":91,"summary":"Strong fit"}' }] }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  let acked = false;
  try {
    await worker.queue({ messages: [{ body: { leadId, source: "test" }, ack() { acked = true; }, retry() { throw new Error("unexpected retry"); } }] }, env);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(acked, true);
  assert.equal(DB.leads.get(leadId).status, "ready");
  assert.equal(DB.leads.get(leadId).score, 91);
  assert.equal(reports.size, 1);
  assert.equal([...DB.runs.values()][0].status, "complete");
});

test("scheduled reconciliation requeues unfinished work", async () => {
  const { env, DB, sent } = environment();
  DB.leads.set("lead_retry", { id: "lead_retry", status: "retry", attempts: 1 });
  let pending;
  await worker.scheduled({}, env, { waitUntil(promise) { pending = promise; } });
  await pending;
  assert.deepEqual(sent, [{ leadId: "lead_retry", source: "scheduled-reconcile" }]);
});

test("public intake rate limits one source before it can create unbounded model work", async () => {
  const { env, DB, sent } = environment();
  for (let index = 0; index < 20; index += 1) {
    const response = await worker.fetch(new Request("https://app.test/api/intake", {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.10" },
      body: JSON.stringify({ name: `Lead ${index}`, email: `lead${index}@example.com` }),
    }), env);
    assert.equal(response.status, 202);
  }
  const blocked = await worker.fetch(new Request("https://app.test/api/intake", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.10" },
    body: JSON.stringify({ name: "Overflow", email: "overflow@example.com" }),
  }), env);
  assert.equal(blocked.status, 429);
  assert.equal(DB.leads.size, 20);
  assert.equal(sent.length, 20);
});

test("duplicate queue deliveries run the model once and exhausted failures stop retrying", async () => {
  const { env, DB } = environment();
  DB.leads.set("lead_once", { id: "lead_once", name: "Jason", email: "jason@example.com", company: "Loop Co", status: "queued", attempts: 0 });
  DB.leads.set("lead_exhausted", { id: "lead_exhausted", name: "Ameer", email: "ameer@example.com", company: "Loop Co", status: "retry", attempts: 2 });
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (_url, options) => {
    calls += 1;
    const requestText = JSON.parse(options.body).messages[0].content;
    if (requestText.includes("Ameer")) return new Response("unavailable", { status: 503 });
    return new Response(JSON.stringify({ content: [{ type: "text", text: '{"score":88,"summary":"Qualified once"}' }] }), { status: 200 });
  };
  const events = [];
  const message = (leadId) => ({
    body: { leadId, source: "test" },
    ack() { events.push(`${leadId}:ack`); },
    retry() { events.push(`${leadId}:retry`); },
  });
  try {
    await worker.queue({ messages: [message("lead_once"), message("lead_once"), message("lead_exhausted")] }, env);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(calls, 2);
  assert.equal(DB.leads.get("lead_once").status, "ready");
  assert.equal(DB.leads.get("lead_exhausted").status, "failed");
  assert.deepEqual(events, ["lead_once:ack", "lead_once:ack", "lead_exhausted:ack"]);
});
