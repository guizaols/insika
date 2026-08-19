# frozen_string_literal: true

require_relative "insika/version"
require_relative "insika/errors"
# the payload selection + the domain-boundary audit yardstick.
# Pure module — loaded by the gemspec too, so it carries no app requires.
require_relative "insika/packaging"
require_relative "insika/provider_error_classifier"
require_relative "insika/token_store"
require_relative "insika/budget_ledger"
require_relative "insika/circuit_state"
require_relative "insika/reliability"
require_relative "insika/routing"
require_relative "insika/media"
require_relative "insika/alert_dispatcher"
require_relative "insika/outcome_store"
require_relative "insika/retention"
require_relative "insika/funnel_declaration"
require_relative "insika/funnel_store"
require_relative "insika/funnel_fold"
# the parsed follow-up policy of ONE agent — the ONLY shape the
# engine accepts (tool/engine/doctor/Studio share it). Pure value object.
require_relative "insika/followup_policy"
# the contact-state cells and the follow-up schedule records.
# Both are dumb domain stores over the injected backend.
require_relative "insika/contact_store"
require_relative "insika/followup_store"
# the tick-driven firer — rides the same tick as retention/funnel.
require_relative "insika/followup_engine"
# IANA zone resolution through the OS tz database — the stdlib-only route
# to a zone NAME (Follow-up quiet hours, the cron scheduler, the doctor).
require_relative "insika/timezone"
# the recurring schedule: the five-field cron subset + next-fire
# materialization, the declaration parse, the per-agent rows, and the
# tick-driven firer (the recurring half of the tick).
require_relative "insika/cron"
require_relative "insika/schedule"
require_relative "insika/schedule_store"
require_relative "insika/schedule_engine"
# the report destination — one record per run, no
# versioning; the signing half of the sharing link (HMAC, no secret stored).
require_relative "insika/artifact_store"
require_relative "insika/artifact_signing"
require_relative "insika/commands/freeze_funnel_baseline"
require_relative "insika/channels/webhook"
require_relative "insika/coercion"
require_relative "insika/message_origin"
require_relative "insika/env_schema"
require_relative "insika/allowlist"
require_relative "insika/event"
require_relative "insika/agent_profile"
require_relative "insika/subagent_graph"
require_relative "insika/model_policy"
require_relative "insika/model_selection"
require_relative "insika/model_resolver"
require_relative "insika/tool_definition"
require_relative "insika/tool_manifest"
# the pack's grounding policy (Insika::Grounding + the
# GroundingMatcher it wraps). Pure Ruby — profile data, parsed per turn.
require_relative "insika/grounding"
require_relative "insika/frontmatter"
require_relative "insika/token_estimator"
require_relative "insika/checkpoint"
require_relative "insika/command"
require_relative "insika/hooks"
require_relative "insika/middleware"
# Production edge: windowed counters + the rate-limit/cost
# Middleware. Both inert until configured (nil/0 = off).
require_relative "insika/usage_ledger"
require_relative "insika/budget_ledger"
require_relative "insika/edge_limiter"
require_relative "insika/tool_output_compressor"
# Content safety / guardrails. The pattern SOURCE is the
# language-tagged data in safety/corpus.rb; detectors.rb compiles it. Both are
# self-contained (the eval requires detectors.rb directly); the rest hang off
# Middleware/hooks seams. No ruby_llm at load-time — Factory requires the gem
# lazily, like the Executor's create_chat.
require_relative "insika/safety/corpus"
require_relative "insika/safety/detectors"
require_relative "insika/safety/safe_responses"
require_relative "insika/safety/config"
require_relative "insika/safety/moderator"
require_relative "insika/safety/output_filter"
require_relative "insika/safety/input_guardrail"
require_relative "insika/safety/output_validator"
require_relative "insika/safety/factory"
require_relative "insika/context/fragment"
require_relative "insika/context/priority"
require_relative "insika/context/provider"
require_relative "insika/context/catalog_provider"
require_relative "insika/context/builder"
require_relative "insika/context/providers/request"
require_relative "insika/context/providers/prompt"
require_relative "insika/context/providers/skill"
require_relative "insika/context/providers/skill_trigger"
require_relative "insika/context/providers/tool_search"
require_relative "insika/context/providers/memory"
require_relative "insika/context/providers/session"
require_relative "insika/context/providers/briefing"
# the cache-prefix hash chain + the per-agent cache-hit series.
# Both are referenced by the Executor at runtime, so they load before it.
require_relative "insika/prefix_fingerprint"
require_relative "insika/cache_series_store"
require_relative "insika/policy/policy"
require_relative "insika/policy/engine"
require_relative "insika/registry"
require_relative "insika/tool_registry"
require_relative "insika/workflow"
require_relative "insika/workflow_registry"
require_relative "insika/policy_registry"
require_relative "insika/capability_registry"
require_relative "insika/prompt_catalog"
require_relative "insika/plugin"
require_relative "insika/plugin/loader"
require_relative "insika/store"
require_relative "insika/stores/memory"
require_relative "insika/stores/sqlite"
require_relative "insika/session_store"
require_relative "insika/task_store"
require_relative "insika/checkpoint_store"
require_relative "insika/pending_action_store"
require_relative "insika/delegation_store"
# Channels: the outbound record + the inbound retry window. Both are
# plain stores; the channel objects themselves come after the HTTP client.
require_relative "insika/outbox_store"
require_relative "insika/shadow_pair_store"
require_relative "insika/inbound_log"
require_relative "insika/memory_store"
# the operator-mutation audit trail. After memory_store (no
# mutual deps). Pure stdlib — `load_guard_spec` stays green.
require_relative "insika/memory_audit_store"
require_relative "insika/config_store"
require_relative "insika/profile_source"
require_relative "insika/agent_file_store"
require_relative "insika/skill_store"
require_relative "insika/secret_masking"
require_relative "insika/tool_store"
require_relative "insika/tool_trace_store"
require_relative "insika/context_trace_store"
# the model-visible payload of one ask + its durable trace —
# "model-visible means logged" (the conformance suite's reconstruction half).
require_relative "insika/model_visible"
require_relative "insika/model_visible_trace_store"
# Refinement: the run record + the evidence half of the loop.
# Reads sessions/tasks/traces above; requires Safety::Detectors (loaded earlier) for
# the PII redaction of the snippets it puts in a report.
require_relative "insika/refinement_store"
require_relative "insika/refinement/evidence_collector"
# The candidate format is pure data + validation, so it loads with the collector;
# the GATE needs the evals module and the stores, so it waits for them below.
require_relative "insika/refinement/candidate"
# The proposer only needs the candidate format and an injected `ask` — the provider
# gem is required lazily, inside the factory, so requiring Insika still loads nothing.
require_relative "insika/refinement/proposer"
require_relative "insika/egress_guard"
require_relative "insika/schema_guard"
# the evidence contract (Spec + Processor + EvidenceLedger). Pure Ruby.
# Required BEFORE tool_envelope.rb — the envelope references it at runtime.
require_relative "insika/evidence"
require_relative "insika/sandbox"
require_relative "insika/http_client"
# Channels: the registry, the bundled relay adapter and the
# out-of-band dispatcher. After http_client and egress_guard — the relay POSTs
# through both — and after registry.rb, which ChannelRegistry extends.
require_relative "insika/channel_registry"
require_relative "insika/channels/relay"
require_relative "insika/channels/web"
require_relative "insika/channel_delivery"
require_relative "insika/overlay_tool_registry"
require_relative "insika/settings_store"
require_relative "insika/llm_provider_store"
require_relative "insika/llm_configurator"
# LLM-first onboarding surface: serves start.md + models.json + the
# public docs. Reads the settings/provider stores above at call-time (order is free).
require_relative "insika/onboarding"
# Evals — the quality harness, moved under lib/ so the engine can call it
# (the refinement gate scores a candidate agent with the SAME judge the CLI
# uses; a second copy would be the worst outcome). It stays a CLIENT of the engine:
# HttpTransport talks to a running deployment, nothing here reads a store. Pure Ruby +
# stdlib; the judge's provider call is injected, so no ruby_llm at load time.
require_relative "insika/evals/golden"
require_relative "insika/evals/assertions"
require_relative "insika/evals/judge"
require_relative "insika/evals/pairwise"
require_relative "insika/evals/runner"
require_relative "insika/evals/report"
require_relative "insika/evals/baseline"
require_relative "insika/evals/transport"
# shadow parity: the frozen criterion and the mechanical
# fold over the pair store (C6). Pure — no store, no provider gem.
require_relative "insika/parity/criterion"
require_relative "insika/parity/verdict"
# Authored eval cases: the corpus becomes editable without a
# checkout. Requires the loader above (it is the one validator).
require_relative "insika/golden_store"
require_relative "insika/baseline_store"
# scores a candidate by REPLAYING it. After evals (the runner and
# the baseline comparison) and after the stores it clones an agent through.
require_relative "insika/refinement/gate"
# the proposer PANEL and the run's token budget. Needs the
# candidate format and the gate's Report shape, so it loads after both.
require_relative "insika/refinement/panel"
require_relative "insika/mcp_store"
require_relative "insika/mcp_http_client"
require_relative "insika/mcp_tool_ingestor"
require_relative "insika/system_file_store"
require_relative "insika/recovery"
require_relative "insika/command_bus"
require_relative "insika/commands/create_session"
require_relative "insika/commands/cancel_task"
require_relative "insika/commands/pause_task"
require_relative "insika/commands/approve_action"
require_relative "insika/commands/send_message"
require_relative "insika/commands/resume_task"
require_relative "insika/commands/trigger_workflow"
require_relative "insika/commands/agent_payload"
require_relative "insika/commands/create_agent"
require_relative "insika/commands/update_agent"
require_relative "insika/commands/delete_agent"
require_relative "insika/commands/set_agent_tools"
require_relative "insika/commands/write_agent_file"
require_relative "insika/commands/delete_agent_file"
require_relative "insika/commands/restore_agent_file"
require_relative "insika/commands/write_skill"
require_relative "insika/commands/delete_skill"
require_relative "insika/commands/set_skill_agents"
require_relative "insika/commands/memory_put_fact"
require_relative "insika/commands/memory_forget_fact"
require_relative "insika/commands/memory_add_note"
require_relative "insika/commands/run_refinement"
require_relative "insika/commands/gate_refinement"
require_relative "insika/commands/resolve_refinement"
require_relative "insika/commands/write_golden"
require_relative "insika/commands/update_settings"
require_relative "insika/commands/upsert_llm_provider"
require_relative "insika/commands/delete_llm_provider"
require_relative "insika/commands/issue_tenant_token"
require_relative "insika/commands/revoke_token"
require_relative "insika/commands/rotate_tenant_token"
require_relative "insika/commands/record_outcome"
require_relative "insika/commands/record_shadow_reply"
require_relative "insika/commands/judge_shadow_pairs"
require_relative "insika/commands/session_purge"
require_relative "insika/commands/forget_customer"
require_relative "insika/commands/delete_tenant_data"
# the LGPD access right — export one customer's memory cell as
# content (the Studio download); the event stays counts-only.
require_relative "insika/commands/export_customer_memory"
# the operator/integration follow-up mutations (cancel one
# record; revoke a contact + fall its pending records atomically).
require_relative "insika/commands/cancel_followup"
require_relative "insika/commands/revoke_contact"
# the report destination's Studio mutation — delete one artifact
# (a bus command, like every Studio mutation).
require_relative "insika/commands/delete_artifact"
# session distillation — the distiller (pure, injected ask)
# and the proposal store (proposals + the latched dedup ledger + the
# per-session distilled marker).
require_relative "insika/distill"
require_relative "insika/proposal_store"
require_relative "insika/commands/run_distillation"
require_relative "insika/distill_engine"
require_relative "insika/commands/resolve_proposal"
# the gated harvest — the miner (pure, injected ask), the
# frozen conversion criterion and the versioned negative list. The provider
# touch stays inside MinerFactory's lazy ask (load_guard stays green).
require_relative "insika/harvest"
require_relative "insika/harvest/criterion"
require_relative "insika/harvest/negative_list"
require_relative "insika/harvest/conversion_gate"
require_relative "insika/harvest/gate"
require_relative "insika/harvest_store"
require_relative "insika/commands/run_harvest"
require_relative "insika/commands/gate_harvest"
require_relative "insika/commands/promote_harvest"
require_relative "insika/commands/rollback_harvest"
require_relative "insika/commands/reject_harvest"
require_relative "insika/harvest_engine"
require_relative "insika/commands/upsert_mcp"
require_relative "insika/commands/delete_mcp"
require_relative "insika/commands/write_system_file"
require_relative "insika/commands/delete_system_file"
require_relative "insika/commands/restore_system_file"
require_relative "insika/commands/write_data_tool"
require_relative "insika/commands/delete_data_tool"
require_relative "insika/commands/restore_data_tool"
require_relative "insika/commands/import_tools"
require_relative "insika/commands/import_mcp_tools"
require_relative "insika/event_stream"
require_relative "insika/task_actor"
require_relative "insika/queue_policy"
require_relative "insika/session_actor"
require_relative "insika/skill_catalog"
require_relative "insika/tool_catalog"
require_relative "insika/steer_injector"
require_relative "insika/loop_detector"
require_relative "insika/balloon_splitter"
require_relative "insika/turn_output"
require_relative "insika/turn_state"
require_relative "insika/turn_timing"
require_relative "insika/capability/resolved_tool"
require_relative "insika/tool_envelope"
require_relative "insika/tool_assembly"
require_relative "insika/chat_builder"
require_relative "insika/executor"
require_relative "insika/shutdown"
require_relative "insika/tick"
require_relative "insika/pack"
require_relative "insika/pack_importer"
require_relative "insika/telemetry"
# Strict config + diagnosis. Doctor reads the config stores above;
# EnvSchema (required at the top) is its env layer.
require_relative "insika/doctor"
# Soak: the 72h uptime-degradation harness. Pure stdlib — the
# envelope and the report fold are deterministic, the runner only talks Net::HTTP.
require_relative "insika/soak/envelope"
require_relative "insika/soak/report"
require_relative "insika/soak/runner"
require_relative "insika/vitals"
# Shared composition core for both roots (config/wiring.rb + config/deployment.rb).
# Only references the classes above at call-time, so require order is unconstrained.
require_relative "insika/wiring/graph"
# Public Ruby DSL: Insika.agent { … }. The Builder is gem-free (it only
# generates a Pack); the runtime (chat/serve) is required lazily by Definition, so
# `require "insika"` stays free of ruby_llm and the HTTP server.
require_relative "insika/dsl"
# Do NOT require "insika/tools/load_skill" here: it does `require "ruby_llm"` at
# the top (inherits from RubyLLM::Tool) and would pull the gem in at load-time. The
# Executor loads it lazily inside create_chat.
