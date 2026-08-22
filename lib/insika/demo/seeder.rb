# frozen_string_literal: true

require "securerandom"
require "time"

module Insika
  module Demo
    # Populates one instance with enough realistic-looking data to see every
    # loop working at once: a funnel with a frozen baseline, follow-ups in all
    # four states, refinement runs across the lifecycle, pending + resolved
    # approvals, distillation proposals/facts, and a golden set with a
    # baseline. Writes ONLY through the same domain-store APIs a real turn
    # would use (OutcomeStore#create + FunnelFold, FollowupStore#create +
    # transitions, ...) — there is no bulk/bypass path, by design (D1: the
    # engine never hard-codes a shortcut for its own demo).
    #
    # `force: false` (default) is a no-op once the demo agent exists — safe
    # to run more than once. `force: true` re-seeds on top: it re-recomputes
    # the funnel cleanly (FunnelFold#recompute always wipes its own pair
    # first) but APPENDS a fresh batch of followups/refinement runs/
    # approvals/proposals/goldens, because none of those stores expose a
    # scoped bulk-delete that a shared "platform" tenant could safely call
    # without risking another agent's data (FollowupStore#purge/
    # ProposalStore#purge are TENANT-wide, not per-agent).
    class Seeder
      FUNNEL_DAYS = 40

      def initialize(profiles:, store:, session_store:, task_store:, outcome_store:,
                     funnel_store:, followup_store:, refinement_store:,
                     pending_action_store:, proposal_store:, memory_store:,
                     golden_store:, baseline_store:, event_stream:)
        @profiles = profiles
        @store = store
        @session_store = session_store
        @task_store = task_store
        @outcome_store = outcome_store
        @funnel_store = funnel_store
        @followup_store = followup_store
        @refinement_store = refinement_store
        @pending_action_store = pending_action_store
        @proposal_store = proposal_store
        @memory_store = memory_store
        @golden_store = golden_store
        @baseline_store = baseline_store
        @event_stream = event_stream
      end

      # -> { seeded: false, reason:, agent: } | { seeded: true, agent:, counts: {…} }
      def seed!(force: false)
        existing = @profiles.fetch(Demo::AGENT_ID)
        return { seeded: false, reason: "already_seeded", agent: Demo::AGENT_ID } if existing && !force

        # A distinct suffix per call: `force: true` on top of an existing
        # batch would otherwise collide on FollowupStore's own dedup rule (one
        # pending record per tenant+agent+customer+reason) and raise.
        @batch = SecureRandom.hex(3)
        seed_agent!(existing)
        # `funnel_outcomes` runs LAST: `seed_followups!` writes one extra
        # "purchased" outcome (the nudge's conversion, for the A/B card) —
        # the fold has to see it, or it sits un-folded until some later pass.
        counts = {
          followups: seed_followups!,
          refinement_runs: seed_refinement!,
          approvals: seed_approvals!,
          distillation_proposals: seed_distillation!,
          golden_cases: seed_evals!,
          funnel_outcomes: seed_sessions_and_funnel!
        }
        { seeded: true, agent: Demo::AGENT_ID, counts: counts }
      end

      private

      # --- agent -----------------------------------------------------------

      def seed_agent!(existing)
        handler = existing ? Insika::Commands::UpdateAgent.new(profile_source: @profiles, event_stream: @event_stream)
                            : Insika::Commands::CreateAgent.new(profile_source: @profiles, event_stream: @event_stream)
        type = existing ? :update_agent : :create_agent
        handler.call(Insika::Command.build(type, Demo::AGENT_ATTRS))
      end

      # --- funnel: FUNNEL_DAYS of outcomes, folded, then frozen -------------

      def seed_sessions_and_funnel!
        declaration = Insika::FunnelDeclaration.parse!(Demo::AGENT_ATTRS[:funnel])
        created = 0
        FUNNEL_DAYS.downto(1) do |days_ago|
          at = Time.now.utc - (days_ago * 86_400)
          day_counts(at).each { |stage, n| created += record_stage(stage, n, at) }
        end

        Insika::FunnelFold.new(outcome_store: @outcome_store, funnel_store: @funnel_store,
                               profiles: @profiles, store: @store)
                          .recompute(tenant: nil, agent: Demo::AGENT_ID, declaration: declaration)
        Insika::Commands::FreezeFunnelBaseline.new(funnel_store: @funnel_store, profiles: @profiles,
                                                    event_stream: @event_stream)
                          .call(Insika::Command.build(:freeze_funnel_baseline, { agent: Demo::AGENT_ID }))
        created
      end

      # A believable e-commerce dropout: each stage keeps a random fraction
      # of the one before it.
      def day_counts(at)
        greeted = rand(4..9)
        browsing = (greeted * rand(0.5..0.7)).round
        cart = (browsing * rand(0.3..0.45)).round
        checkout = (cart * rand(0.45..0.65)).round
        purchased = (checkout * rand(0.55..0.8)).round
        { "greeted" => greeted, "browsing" => browsing, "cart_started" => cart,
          "checkout_started" => checkout, "purchased" => purchased }
      end

      def record_stage(stage, count, at)
        count.times do
          value = stage == "purchased" ? rand(60.0..320.0).round(2) : 0.0
          @outcome_store.create(tenant: nil, agent: Demo::AGENT_ID, outcome: stage, value: value, at: at)
        end
        count
      end

      # --- follow-ups: one per state ----------------------------------------

      def seed_followups!
        pending_followup!(customer: batch_customer(1), reason: "cart_abandoned", arm: "control")

        nudge_session = new_task_session!("I'll take the blue sneakers after all")
        fire_followup!(customer: batch_customer(2), reason: "cart_abandoned", arm: "nudge",
                       session: nudge_session[:session], task: nudge_session[:task])
        @outcome_store.create(tenant: nil, agent: Demo::AGENT_ID, session_id: nudge_session[:session].id,
                              outcome: "purchased", value: 89.9)

        control_session = new_task_session!("thinking about it, maybe later")
        fire_followup!(customer: batch_customer(3), reason: "cart_abandoned", arm: "control",
                       session: control_session[:session], task: control_session[:task])

        cancelled = pending_followup!(customer: batch_customer(4), reason: "no_response", arm: "nudge")
        @followup_store.cancel(id: cancelled.id)

        blocked = pending_followup!(customer: batch_customer(5), reason: "reminder", arm: "nudge")
        @followup_store.block(id: blocked.id, reason: "quiet_hours")

        5
      end

      # Distinct per seed! call (see @batch) — the store refuses two pending
      # records for the same (tenant, agent, customer, reason) tuple, and a
      # force reseed must not collide with the previous batch's still-pending
      # one.
      def batch_customer(n) = "demo-customer-#{n}-#{@batch}"

      def pending_followup!(customer:, reason:, arm:)
        @followup_store.create(tenant: nil, agent: Demo::AGENT_ID, customer: customer,
                               session_id: @session_store.create.id, at: Time.now.utc + 3600,
                               reason: reason, arm: arm, transport: "web")
      end

      def fire_followup!(customer:, reason:, arm:, session:, task:)
        record = @followup_store.create(tenant: nil, agent: Demo::AGENT_ID, customer: customer,
                                        session_id: session.id, at: Time.now.utc + 3600,
                                        reason: reason, arm: arm, transport: "web")
        @followup_store.transition_fired(id: record.id, task_id: task.id)
        finish_task!(task)
      end

      # --- refinement: one run per stage of the lifecycle -------------------

      def seed_refinement!
        awaiting_approval_run!
        applied_run!
        rejected_run!
        no_findings_run!
        4
      end

      def awaiting_approval_run!
        run = @refinement_store.create(agent_id: Demo::AGENT_ID, window: { "last_sessions" => 50 })
        @refinement_store.complete(run.id, findings: [repeated_price_finding])
        candidate = discipline_candidate
        @refinement_store.gating(run.id, candidate: candidate)
        @refinement_store.gated(run.id, report: passing_gate_report(candidate))
      end

      def applied_run!
        run = @refinement_store.create(agent_id: Demo::AGENT_ID, window: { "last_sessions" => 50 })
        @refinement_store.complete(run.id, findings: [repeated_price_finding])
        candidate = discipline_candidate
        @refinement_store.gating(run.id, candidate: candidate)
        @refinement_store.gated(run.id, report: passing_gate_report(candidate))
        @refinement_store.resolve(run.id, decision: :applied, operator: "demo-seed",
                                  note: "Looks safe — applying to AGENTS.md.")
      end

      def rejected_run!
        run = @refinement_store.create(agent_id: Demo::AGENT_ID, window: { "last_sessions" => 30 })
        @refinement_store.complete(run.id, findings: [off_topic_finding])
        candidate = off_topic_candidate
        @refinement_store.gating(run.id, candidate: candidate)
        @refinement_store.gated(run.id, report: failing_gate_report(candidate))
      end

      def no_findings_run!
        run = @refinement_store.create(agent_id: Demo::AGENT_ID, window: { "last_sessions" => 20 })
        @refinement_store.complete(run.id, findings: [])
      end

      def repeated_price_finding
        { "kind" => "repeated_price_without_stock_check", "count" => 4,
          "title" => "Repeats a price without checking stock",
          "detail" => "asked the price of the same item twice; the agent repeated it verbatim " \
                      "without a stock check" }
      end

      def off_topic_finding
        { "kind" => "answers_off_topic_questions", "count" => 2,
          "title" => "Answers questions unrelated to the store",
          "detail" => "answered a question about the weather instead of redirecting to store topics" }
      end

      def discipline_candidate
        { "id" => SecureRandom.uuid, "proposer" => "demo-seed",
          "rationale" => "Customers who ask about the same product twice get the same price restated " \
                         "without a stock check — a stale price can be quoted after a sellout.",
          "edits" => [{ "file" => "AGENTS.md", "op" => "append", "anchor" => nil, "before" => nil,
                        "after" => "Always confirm current stock before repeating a price.",
                        "addresses" => ["repeated_price_without_stock_check"] }],
          "dropped" => [] }
      end

      def off_topic_candidate
        { "id" => SecureRandom.uuid, "proposer" => "demo-seed",
          "rationale" => "The agent occasionally answers off-topic questions instead of redirecting.",
          "edits" => [{ "file" => "AGENTS.md", "op" => "append", "anchor" => nil, "before" => nil,
                        "after" => "Never answer questions unrelated to the store; redirect politely.",
                        "addresses" => ["answers_off_topic_questions"] }],
          "dropped" => [] }
      end

      def passing_gate_report(candidate)
        { "passed" => true, "candidate_id" => candidate["id"], "cases" => 12, "passed_cases" => 12,
          "regressions" => [] }
      end

      def failing_gate_report(candidate)
        { "passed" => false, "candidate_id" => candidate["id"], "cases" => 10, "passed_cases" => 7,
          "regressions" => ["demo-store-off-topic"], "reason" => "3 case(s) regressed" }
      end

      # --- approvals: 2 pending + 1 resolved --------------------------------

      def seed_approvals!
        [
          ["I want a refund for order #10234, the shoes don't fit", "issue_refund",
           { "order_id" => "10234", "amount" => 89.9 }],
          ["can you apply the WELCOME10 discount code retroactively?", "apply_discount_code",
           { "order_id" => "10391", "code" => "WELCOME10" }]
        ].each do |message, tool, args|
          task = new_task_session!(message)[:task]
          @pending_action_store.create(task_id: task.id, turn: 3, tool: tool, args: args)
          finish_task!(task)
        end

        task = new_task_session!("please cancel order #10500 and refund me")[:task]
        pending = @pending_action_store.create(task_id: task.id, turn: 2, tool: "cancel_order",
                                               args: { "order_id" => "10500" })
        @pending_action_store.resolve(pending.id, decision: :approved, operator: "demo-seed")
        finish_task!(task)

        3
      end

      # --- distillation: proposals + one approved fact ----------------------

      def seed_distillation!
        session6 = distillation_session!("demo-customer-6", "I usually pay with Pix, is that ok here too?")
        @proposal_store.create(tenant: nil, customer: "demo-customer-6", session_ref: session6.id,
                               key: "preferred_payment_method", value: "pix", confidence: 0.82, evidence: [0])

        session7 = distillation_session!("demo-customer-7", "I'm always browsing the electronics section")
        approved = @proposal_store.create(tenant: nil, customer: "demo-customer-7", session_ref: session7.id,
                                          key: "favorite_category", value: "electronics", confidence: 0.9,
                                          evidence: [0])
        @proposal_store.approve(id: approved.id, operator: "demo-seed", note: "Confirmed across 3 conversations.")
        @memory_store.put_fact(tenant: nil, customer: "demo-customer-7", key: "favorite_category",
                               value: "electronics", origin: "distilled:#{approved.id}")

        session8 = distillation_session!("demo-customer-8", "I wear a size 42, I think")
        rejected = @proposal_store.create(tenant: nil, customer: "demo-customer-8", session_ref: session8.id,
                                          key: "shoe_size", value: "42", confidence: 0.4, evidence: [0])
        @proposal_store.reject(id: rejected.id, operator: "demo-seed", note: "Confidence too low, likely a typo.")

        3
      end

      # A real Session (not a bare string) so the Facts page's evidence link
      # resolves — a plain id would 404 on /studio/sessions/:id.
      def distillation_session!(customer, message)
        session = @session_store.create(vars: { "customer" => customer, "agent" => Demo::AGENT_ID })
        @session_store.append_messages(session.id, { "role" => "user", "content" => message })
        session
      end

      # --- evals: the golden set + a mixed pass/fail baseline ---------------

      def seed_evals!
        ids = Demo::GOLDEN_CASES.map { |raw| @golden_store.write(raw).id }
        last = ids.size - 1
        cases = ids.each_with_index.to_h do |id, i|
          [id, i == last ? { "pass" => false, "score" => 0.42 } : { "pass" => true, "score" => (0.75 + i * 0.03).round(2) }]
        end
        @baseline_store.put(Demo::AGENT_ID, { "cases" => cases })
        ids.size
      end

      # --- shared: a Session + one user Task, like a real turn would leave --

      def new_task_session!(message)
        session = @session_store.create(vars: { "customer" => SecureRandom.uuid, "agent" => Demo::AGENT_ID })
        command = Insika::Command.build(:send_message, { agent: Demo::AGENT_ID, message: message })
        task = @task_store.create(command: command.to_h, session_id: session.id)
        { session: session, task: task }
      end

      # Lands a fresh task in a TERMINAL status (queued -> running ->
      # completed). A seeded task must never sit at :running/:waiting/:paused
      # (or even :queued) once seeding is done — Recovery's boot sweep reads
      # those as an interrupted turn and either dispatches a real resume (no
      # LLM configured -> a pointless failure) or fails the task outright for
      # want of a checkpoint that was never real. Terminal is inert either way.
      def finish_task!(task)
        @task_store.transition(task.id, to: :running)
        @task_store.transition(task.id, to: :completed)
      end
    end
  end
end
