---
name: nats-zig 0.2.2 consumer envelope incompatible with NATS 2.14+
description: js.createConsumer in nats-zig 0.2.2 sends the legacy ≤2.13 JSON envelope; 2.14 rejects it. Hand-roll the request with the new envelope or fork.
type: feedback
originSessionId: 9faac8f3-1919-4d81-aa68-07970ec6fc44
---
`nats.JetStream.Context.createConsumer(...)` in nats-zig 0.2.2 (the
version pinned at v0.2.2 in `build.zig.zon`) serializes the consumer
config with `durable_name` at the top level of the JSON body:

```json
{"durable_name":"...","ack_policy":"explicit",...}
```

That envelope is the pre-2.14 shape. NATS 2.14 (released 2026-04-30,
adopted in `infra/compose.yml` 2026-05-01) rejects it with:

```
err_code 10025 — invalid JSON: json: unknown field "durable_name"
```

**Why:** 2.14 hardened the API to require a wrapper:
`{"stream_name":"...","config":{"durable_name":"...",...}}`. nats-zig
0.2.2 hasn't been updated.

**How to apply:**
- Don't call `js.createConsumer(...)` against a 2.14+ broker until
  nats-zig publishes a 2.14-aware tag.
- Bypass with `client.request("$JS.API.CONSUMER.CREATE.<stream>.<durable>", body, timeout)`
  using the wrapped envelope. Pattern in
  `src/services/persistence_writer/main.zig#ensureConsumer` (consumer
  create only — stream create still works because nats-zig's
  serializeStreamConfig has no top-level field that 2.14 renamed).
- Detect errors by scanning the response for `"error":{` — there's no
  err_code on success.
- When nats-zig 0.3+ ships, drop the hand-rolled call and switch back
  to `js.createConsumer`. Update this memory.

**Remember:** Same envelope rule applies to `streamInfo`/`consumerInfo`
on 2.14+ — no body sent, so they still work. The risk is in any
nats-zig API that POSTs a config body. If you hit a similar
`unknown field` error elsewhere, suspect this same envelope drift.
