# frozen_string_literal: true

require "time"

module Insika
  # RFC-0033 C5: the tick-driven FIRER of follow-up records (RFC §4.2). One
  # pass per claim window; each record is its own claim (pending -> fired + task
  # creation + the contact bump in ONE transaction — D5). Gating order (D6):
  #
  #   policy valid? -> contact state (never-granted / revoked / unavailable ->
  #   block) -> quiet hours? (pending — DEFER) -> dedup guard (block) ->
  #   frequency ceiling (block) -> FIRE.
  #
  # Blocking is at fire time, never at schedule time; a `blocked` record is
  # auditable, never silent. The engine never modifies a policy and never
  # invents a reason — the turn it creates is delivered entirely by the existing
  # pipeline (it holds no channel code).
  class FollowupEngine
    SCOPE = "followup_fire"
    KEY = "claim"
    DEFAULT_WINDOW = 300 # seconds; one firing worker per window

    # The engine's kick text. The agent composes the customer-visible message
    # itself — the engine never writes a word the customer reads. %{reason} and
    # %{now} (UTC) are empty-escaped.
    FIRING_PROMPT = "You are following up on a previous conversation, as " \
                    "scheduled and with the customer's consent. The follow-up " \
                    "reason: %{reason}. It is now %{now} (UTC). Write ONE short " \
                    "follow-up message to the customer now, referencing the " \
                    "earlier conversation."

    def initialize(store:, followup_store:, contact_store:, task_store:,
                   profiles:, executor:, window: DEFAULT_WINDOW,
                   now: nil, logger: nil, event_stream: nil)
      @store = store
      @followup_store = followup_store
      @contact_store = contact_store
      @task_store = task_store
      @profiles = profiles
      @executor = executor
      @window = window
      @now = now
      @logger = logger
      @event_stream = event_stream
    end

    # -> { claimed: false }
    #  | { claimed: true, fired: N, blocked: N, errors: N,
    #      blocked_reasons: { "rule" => N }, deferred: N }
    # A StoreError on ONE record aborts THAT record's transaction (rescued,
    # counted, the loop continues) — a broken record must not hold the other
    # stores' follow-ups hostage.
    def run
      now_time = @now || Time.now.utc
      return { claimed: false } unless claim_window(now_time)

      fired = 0
      blocked = 0
      deferred = 0
      errors = 0
      reasons = Hash.new(0)

      # D7 at fire time: when more than one PENDING record holds the same
      # (customer, reason), only the OLDEST fires. The verdict is snapshotted
      # at pass start — a record that fires earlier in THIS pass must still
      # dedup the younger ones behind it.
      dedup_snapshot = {}
      due = @followup_store.due(now: now_time)
      due.each do |record|
        pair = [record.tenant, record.agent, record.customer, record.reason]
        dedup_snapshot[pair] ||= @followup_store
                                  .pending_for(tenant: record.tenant, agent: record.agent,
                                               customer: record.customer, reason: record.reason)
                                  &.id
      end

      due.each do |record|
        begin
          outcome = fire_record(record, now_time,
                                older_pending_id: dedup_snapshot[[record.tenant, record.agent,
                                                                   record.customer, record.reason]])
          case outcome
          when :fired then fired += 1
          when :deferred then deferred += 1
          when Array
            # a blocked record is auditable, never silent — the failing rule is
            # written down on the record itself (D6/D9).
            @followup_store.block(id: record.id, reason: outcome[1], now: now_time)
            blocked += 1
            reasons[outcome[1].to_s] += 1
          end
        rescue StandardError
          # a broken record must not hold the other records' follow-ups
          # hostage — its own transaction already rolled back.
          errors += 1
        end
      end

      { claimed: true, fired: fired, blocked: blocked, errors: errors,
        blocked_reasons: reasons, deferred: deferred }
    end

    private

    # -> :fired | :deferred | [:blocked, rule]
    def fire_record(record, now_time, older_pending_id: nil)
      profile = @profiles.fetch(record.agent)
      policy = profile && Insika::FollowupPolicy.parse(profile.respond_to?(:followup) ? profile.followup : nil)
      # D9: a malformed policy (or a missing profile) is a BLOCK, never a crash
      # and never a silent fire.
      return [:blocked, :policy_invalid] if policy.nil?

      contact = @contact_store.get(tenant: record.tenant, customer: record.customer)
      return [:blocked, :consent] if contact.nil?       # never messaged (D2)
      return [:blocked, :revoked] if contact.state == "revoked"
      return [:blocked, :unavailable] if contact.state == "unavailable"

      # quiet hours keep the record PENDING — that IS the deferral; the next
      # pass retries it (never a terminal block).
      return :deferred if policy.quiet?(now_time)

      # D7 at fire time: only the OLDEST pending per (customer, reason) fires;
      # a younger pending of the same pair blocks (the snapshot taken at pass
      # start, so a same-pass fire still dedups the younger ones).
      if older_pending_id && older_pending_id != record.id
        return [:blocked, :dedup]
      end

      # frequency: fired sends inside the window already at the ceiling -> block
      if (window = policy.frequency_window) && window[:count].positive?
        sent = @followup_store.fired_in_window(tenant: record.tenant, customer: record.customer,
                                               since: now_time - window[:seconds])
        return [:blocked, :frequency] if sent >= window[:count]
      end

      fire(record, policy, now_time)
      :fired
    end

    # The atomic claim (D5): the record and the turn commit together or
    # together fail. Within ONE transaction: create the synthetic task, flip
    # the record to fired (with the task id), bump the contact counter — and
    # mark :unavailable when the bump reaches the policy's silence ceiling.
    def fire(record, policy, now_time)
      message = format(FIRING_PROMPT, reason: record.reason.to_s, now: now_time.utc.iso8601)
      command = { "type" => "scheduled_followup",
                  "session_id" => record.session_id,
                  "payload" => { "agent" => record.agent, "session_id" => record.session_id,
                                 "customer" => record.customer, "message" => message,
                                 "origin" => Insika::MessageOrigin::SCHEDULED },
                  "meta" => { "tenant" => record.tenant, "transport" => record.transport } }

      @store.transaction do
        task = @task_store.create(command: command, session_id: record.session_id)
        @followup_store.transition_fired(id: record.id, task_id: task.id, now: now_time)
        cell = @contact_store.bump_outbound(tenant: record.tenant, customer: record.customer,
                                            now: now_time)
        if cell.sends_without_reply >= policy.silence_after_sends
          @contact_store.mark_unavailable(tenant: record.tenant, customer: record.customer,
                                          now: now_time)
        end
      end

      # AFTER the commit: spawn. A spawn failure leaves a durable :queued task
      # — the recovery sweep resumes it (a queued task is claimed once).
      task_id = @followup_store.find(record.id).task_id
      task = @task_store.find(task_id)
      profile = @profiles.fetch(record.agent)
      @executor.spawn_in_session(task, profile: profile)
      emit_fired(record, task_id)
      task_id
    end

    # :followup_fired carries ids only — a follow-up record's reason is contact
    # data that rides the record and the Studio, never the event stream.
    def emit_fired(record, task_id)
      return unless @event_stream

      @event_stream.emit(Insika::Event.new(
                           type: :followup_fired,
                           data: { id: record.id, agent: record.agent, customer: record.customer,
                                   task_id: task_id, arm: record.arm },
                           meta: { tenant: record.tenant, at: Time.now.utc.iso8601 }
                         ))
    end

    # The claim window (funnel_fold.rb's idiom — read-check-write on one key
    # inside a transaction): the O(n) scan never rides the 60 s tick, and two
    # workers racing serialize on the backend's lock.
    def claim_window(now_time)
      @store.transaction do
        current = @store.get(SCOPE, KEY)
        last = current && begin
          Time.iso8601(current["claimed_at"].to_s)
        rescue ArgumentError
          nil # a corrupted claim is not a claim — take the window
        end
        if last.nil? || (now_time - last) >= @window
          @store.set(SCOPE, KEY, { "claimed_at" => now_time.iso8601 })
          true
        else
          false
        end
      end
    end
  end
end