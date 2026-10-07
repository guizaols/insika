---
layout: default
title: Shared conversations
---

# Shared conversations

`shared_conversations: true` opts an agent into required central history. The
DSL accepts `shared_conversations true`; stored profiles preserve the flag.
Default is false. Configure `INSIKA_CONVERSATIONS_URL`, a scoped
`INSIKA_CONVERSATIONS_TOKEN`, and a durable native backend (`INSIKA_DB` or
`INSIKA_DATABASE_URL`). A new chat is created centrally on its first turn.
An old chat with `history_required:true` waits for its native history to be
imported; an empty central record never replaces that history.

For Rails, set `INSIKA_TENANCY=multi_tenant`, provision the store tenant and
issue its incoming tenant token. This Rails-facing token is different from
`INSIKA_CONVERSATIONS_TOKEN`, which authenticates Insika to central storage.
The current central token is scoped to one tenant, so use a dedicated pilot
instance for that store. Railway source download, local import and all engine
variables are in the [migration runbook](https://github.com/oitedi/agentshop-memory/blob/feat/shared-conversations/docs/railway-migration.md).

The tenant-authenticated `/v1/responses` request adds `user_text` (original speech)
and `shared_conversation` with UUID `tenant_id`, `user_id`, `agent_id`,
`conversation_id`, `turn_id`, and `message_id`. Keep the
same turn/message IDs across retries. Existing `input` still contains the
presenter/context text used for this request. The authenticated tenant must match.
Omit `generation` to acquire a settled conversation automatically when admitting
the next turn. The engine reads and writes the acquired generation internally.
An explicit integer `generation` retains the legacy ownership check.

Upload incoming media to the central attachment endpoint first. Optional
`shared_conversation.content` carries canonical text/media parts with attachment
IDs; its text must match `user_text`. Generated image/audio bytes upload before
completion. Native checkpoints store attachment bytes and hydrate them at the
RubyLLM boundary. Full tool results retain secret-key masking without prompt caps.

Admission precedes model/tool work. Delivery follows central completion. A lost
completion acknowledgment reuses the native durable result; it never reruns tools.
An uncertain execution stays blocked for operator reconciliation. Only the same
native waiting approval can resume from its checkpoint under the current generation.
Unresolved customer confirmations block switching. Central deletion/outage fails
before cached history is used. Local native purge still requires an explicit cleanup.

Run the isolated HTTP proof (synthetic model/tools, temporary databases):

```sh
SHARED_CONVERSATIONS_SOURCE=/path/to/agentshop-memory bundle exec rspec spec/insika/shared_conversations_http_spec.rb
```


OpenClaw migration imports all registered native sessions without consulting Rails
or requiring a per-chat identity map, even if the Rails chat was deleted. Central
schema 4 allows imported history without a known customer. On first use the engine
assigns the request customer once through the normal conversation PUT, then reads
the existing transcript. Existing resolved customers cannot be replaced. Deploy
central schema 4 before the updated engine; native mode remains independent.
