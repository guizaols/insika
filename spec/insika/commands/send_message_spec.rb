# frozen_string_literal: true

require "spec_helper"

RSpec.describe Insika::Commands::SendMessage do
  subject(:handler) do
    described_class.new(profiles: profiles, session_store: session_store,
                        task_store: task_store, executor: executor,
                        contact_store: contact_store, followup_store: followup_store,
                        store: backend)
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:profile) { Insika::AgentProfile.build(id: "sales", model: "gpt") }
  let(:profiles) { { "sales" => profile } }

  # RFC-0033 C6: the contact hook's collaborators. The default profile has NO
  # followup declaration — the hook is off (parity) unless a test declares one.
  let(:contact_store) { Insika::ContactStore.new(store: backend) }
  let(:followup_store) { Insika::FollowupStore.new(store: backend) }

  # Records the spawn and declines every door (the real fiber is the
  # integration). See spec/support/fake_turn_executor.rb.
  let(:executor) { FakeTurnExecutor.new }

  def payload(**over)
    { agent: "sales", message: "oi" }.merge(over)
  end

  it "happy path: creates a :queued Task with a persisted command, spawns and returns {task_id:}" do
    session = session_store.create(id: "s1")
    result = handler.call(Insika::Command.build(:send_message, payload(session_id: session.id)))

    expect(result).to match({ task_id: kind_of(String) })
    task = task_store.find(result[:task_id])
    expect(task.status).to eq(:queued)
    expect(task.command["type"]).to eq("send_message")
    expect(task.session_id).to eq("s1")
    expect(executor.spawned.size).to eq(1)
    expect(executor.spawned.first.last).to be(profile)
  end

  it "XOR: session_id + history -> ValidationError, no Task created" do
    session_store.create(id: "s1")

    expect do
      handler.call(Insika::Command.build(:send_message,
                                          payload(session_id: "s1", history: [{ role: "user", content: "x" }])))
    end.to raise_error(Insika::ValidationError)
    expect(task_store.each_id.to_a).to be_empty
  end

  it "nonexistent agent -> NotFoundError" do
    expect { handler.call(Insika::Command.build(:send_message, payload(agent: "ghost"))) }
      .to raise_error(Insika::NotFoundError)
  end

  it "missing or empty agent/message -> ValidationError" do
    [payload(agent: ""), payload(agent: nil), payload(message: ""), payload(message: "   ")].each do |pl|
      expect { handler.call(Insika::Command.build(:send_message, pl)) }
        .to raise_error(Insika::ValidationError)
    end
  end

  # WS9's anchor case: a WhatsApp voice note with no caption arrives as parts
  # and nothing else. Demanding a message here made it a 422 at the door — the
  # audio only becomes the message one stage later, inside the turn.
  it "a MEDIA-only message (a voice note, no text) is a turn" do
    session_store.create(id: "s1")
    result = handler.call(Insika::Command.build(
                            :send_message,
                            payload(message: "", session_id: "s1",
                                    parts: [{ "type" => "audio", "url" => "https://cdn.example.com/v.ogg" }])
                          ))

    task = task_store.find(result[:task_id])
    expect(task.status).to eq(:queued)
    expect(task.command["payload"]["parts"].first["type"]).to eq("audio")
  end

  it "empty text with only a TEXT part is still empty (a part is not a loophole)" do
    session_store.create(id: "s1")
    expect do
      handler.call(Insika::Command.build(:send_message,
                                          payload(message: "", session_id: "s1",
                                                  parts: [{ "type" => "text", "text" => "" }])))
    end.to raise_error(Insika::ValidationError)
  end

  it "nonexistent session -> NotFoundError, no Task" do
    expect { handler.call(Insika::Command.build(:send_message, payload(session_id: "ghost"))) }
      .to raise_error(Insika::NotFoundError)
    expect(task_store.each_id.to_a).to be_empty
  end

  it "malformed history -> ValidationError" do
    expect { handler.call(Insika::Command.build(:send_message, payload(history: [{ foo: 1 }]))) }
      .to raise_error(Insika::ValidationError)
  end

  it "one-shot (without session_id/history): Task with session_id nil" do
    result = handler.call(Insika::Command.build(:send_message, payload))

    expect(task_store.find(result[:task_id]).session_id).to be_nil
  end

  it "valid history (without session): spawns, Task without session_id" do
    result = handler.call(Insika::Command.build(:send_message,
                                                 payload(history: [{ role: "user", content: "oi" }])))

    expect(task_store.find(result[:task_id]).session_id).to be_nil
    expect(executor.spawned.size).to eq(1)
  end

  # RFC-0027 C5: t0 is the 202 acceptance — the clock starts HERE, when the task
  # is created, before the debounce window and the SessionActor FIFO. If the
  # mark landed at the pipeline start instead, first_balloon_ms would exclude
  # exactly the wait the debounce imported (with debounce_ms=4000 the Studio
  # would report "<2s atingido" while the customer waits 4s+).
  describe "the channel clock (RFC-0027 C5)" do
    def send_from(transport)
      session_store.create(id: "s1")
      handler.call(Insika::Command.build(:send_message, payload(session_id: "s1"), transport: transport))
    end

    it "a channel transport allocates the clock and stamps :inbound at acceptance" do
      send_from(:"channel:relay")

      timing = executor.spawned_timing.first
      expect(timing).to be_a(Insika::TurnTiming)
      expect(timing.marked?(:inbound)).to be(true)
    end

    it "no clock for a non-channel transport — there is no inbound balloon to measure" do
      send_from(:http)

      expect(executor.spawned_timing.first).to be_nil
    end
  end

  describe "coalescing is offered only where `merged` can be reported" do
    subject(:handler) do
      described_class.new(profiles: profiles, session_store: session_store,
                          task_store: task_store, executor: collecting_executor)
    end

    # Accepts every fragment, so any call that reaches the door merges. The steer door
    # declines throughout: a turn is either still at the door or running, never both.
    let(:collecting_executor) { FakeTurnExecutor.new(collect: "t-open") }

    def send_from(transport, **over)
      session_store.create(id: "s1")
      handler.call(Insika::Command.build(:send_message, payload(session_id: "s1", **over),
                                          transport: transport))
    end

    it "http:json (the aggregated form) coalesces and reports the turn it joined" do
      result = send_from(:"http:json")

      expect(result).to eq({ task_id: "t-open", merged: true })
      expect(collecting_executor.spawned).to be_empty   # no turn of its own
      expect(task_store.each_id.to_a).to be_empty       # and NO orphan :queued task
    end

    it "a channel surface coalesces too (defines the field)" do
      expect(send_from(:"channel:relay")).to eq({ task_id: "t-open", merged: true })
    end

    it "/v1/responses (plain :http) does NOT coalesce — its body cannot carry the verdict" do
      result = send_from(:http)

      expect(result).to match({ task_id: kind_of(String) })
      expect(collecting_executor.asked).to be_empty     # the door was never even opened
      expect(collecting_executor.spawned.size).to eq(1) # a turn of its own, as before
    end

    it "an internal caller (subagent delivery, tests) does not coalesce" do
      expect(send_from(:internal)).to match({ task_id: kind_of(String) })
      expect(collecting_executor.asked).to be_empty
    end

    # `collect`/`steer` move TEXT into a task already at the door; the parts
    # would stay behind, and the customer's photo would silently not exist.
    it "a message carrying MEDIA never joins another turn — it gets its own" do
      result = send_from(:"http:json",
                         parts: [{ "type" => "image", "url" => "https://cdn.example.com/f.png" }])

      expect(result).to match({ task_id: kind_of(String) })
      expect(collecting_executor.asked).to be_empty
      expect(collecting_executor.spawned.size).to eq(1)
    end

    it "validation still runs BEFORE the door: a bad message never reaches collect" do
      session_store.create(id: "s1")

      expect do
        handler.call(Insika::Command.build(:send_message, payload(session_id: "s1", message: "  "),
                                            transport: :"http:json"))
      end.to raise_error(Insika::ValidationError)
      expect(collecting_executor.asked).to be_empty
    end

    it "no pending turn to join -> the ordinary path, with a real task" do
      declining = FakeTurnExecutor.new
      session_store.create(id: "s1")

      result = described_class.new(profiles: profiles, session_store: session_store,
                                   task_store: task_store, executor: declining)
                              .call(Insika::Command.build(:send_message, payload(session_id: "s1"),
                                                           transport: :"http:json"))

      expect(result).to match({ task_id: kind_of(String) })
      expect(declining.spawned.size).to eq(1)
    end
  end

  describe "steering a turn that is already running" do
    # No turn at the door (collect declines), one running (steer accepts).
    let(:steering_executor) { FakeTurnExecutor.new(steer: "t-running") }

    subject(:handler) do
      described_class.new(profiles: profiles, session_store: session_store,
                          task_store: task_store, executor: steering_executor)
    end

    def send_from(transport)
      session_store.create(id: "s1")
      handler.call(Insika::Command.build(:send_message, payload(session_id: "s1"), transport: transport))
    end

    it "answers with the RUNNING turn's id and says the caller does not own the reply" do
      result = send_from(:"http:json")

      expect(result).to eq({ task_id: "t-running", steered: true })
      expect(steering_executor.spawned).to be_empty # no turn of its own
      expect(task_store.each_id.to_a).to be_empty   # and no task at all
    end

    it "is refused on a surface that cannot carry the verdict, exactly like collect" do
      result = send_from(:http)

      expect(result).to match({ task_id: kind_of(String) })
      expect(steering_executor.asked).to be_empty
      expect(steering_executor.spawned.size).to eq(1)
    end
  end

  # interrupt JOINS nothing: this message keeps its own task and its own reply, so
  # there is no verdict to report and therefore no surface to gate.
  describe "interrupting the turn in flight" do
    let(:interrupting_executor) { FakeTurnExecutor.new(interrupt: "t-abandoned") }

    subject(:handler) do
      described_class.new(profiles: profiles, session_store: session_store,
                          task_store: task_store, executor: interrupting_executor)
    end

    def send_from(transport)
      session_store.create(id: "s1")
      handler.call(Insika::Command.build(:send_message, payload(session_id: "s1"), transport: transport))
    end

    it "spawns a turn of its own and names it as what replaced the abandoned one" do
      result = send_from(:"http:json")

      expect(result).to match({ task_id: kind_of(String) })
      expect(interrupting_executor.spawned.size).to eq(1)
      expect(interrupting_executor.interrupts).to eq([["s1", result[:task_id]]])
    end

    it "works on /v1/responses too — there is no verdict it would need to carry" do
      result = send_from(:http)

      expect(result).to match({ task_id: kind_of(String) })
      expect(interrupting_executor.interrupts.first.last).to eq(result[:task_id])
    end

    it "is asked with the task ALREADY created, so the event can correlate the two" do
      result = send_from(:"http:json")

      expect(task_store.find(result[:task_id])).not_to be_nil
    end

    it "a one-shot carries no session, which is what the real door refuses on" do
      handler.call(Insika::Command.build(:send_message, payload, transport: :"http:json"))

      expect(interrupting_executor.interrupts.first.first).to be_nil
    end
  end

  # a platform retrying a webhook it already delivered must not buy
  # a second turn and must not send the customer the same answer twice.
  describe "event_id dedup" do
    subject(:handler) do
      described_class.new(profiles: profiles, session_store: session_store,
                          task_store: task_store, executor: executor, inbound_log: log)
    end

    let(:log) { Insika::InboundLog.new(store: backend) }

    def send_event(id: "wamid.1", transport: :"channel:relay", **over)
      handler.call(Insika::Command.build(:send_message, payload(event_id: id, **over), transport: transport))
    end

    it "runs the turn the first time and remembers which one it was" do
      result = send_event
      expect(result).to match({ task_id: kind_of(String) })
      expect(log.find("channel:relay:wamid.1")).to eq(result[:task_id])
    end

    it "answers the retry with the SAME task and runs nothing" do
      first = send_event
      retried = send_event

      expect(retried).to eq({ task_id: first[:task_id], duplicate: true })
      expect(executor.spawned.size).to eq(1)
      expect(task_store.each_id.to_a.size).to eq(1)
    end

    # Two channels are two consumers with two id spaces; a Slack event id that
    # happened to equal a `wamid` must not silence a real message.
    it "scopes the id by transport" do
      first = send_event(transport: :"channel:relay")
      other = send_event(transport: :"channel:slack")

      expect(other[:task_id]).not_to eq(first[:task_id])
      expect(other).not_to have_key(:duplicate)
    end

    it "does not dedup a caller that sends no event id (at-least-once, honestly)" do
      a = handler.call(Insika::Command.build(:send_message, payload, transport: :"channel:relay"))
      b = handler.call(Insika::Command.build(:send_message, payload, transport: :"channel:relay"))

      expect(a[:task_id]).not_to eq(b[:task_id])
    end

    it "is inert without an inbound log wired (every surface today)" do
      plain = described_class.new(profiles: profiles, session_store: session_store,
                                  task_store: task_store, executor: executor)
      a = plain.call(Insika::Command.build(:send_message, payload(event_id: "wamid.1")))
      b = plain.call(Insika::Command.build(:send_message, payload(event_id: "wamid.1")))

      expect(a[:task_id]).not_to eq(b[:task_id])
    end

    # A duplicate is not a fragment to merge and not a correction to steer with —
    # it is the same message again. Asked before the queue doors for that reason.
    it "beats the coalescing doors to the answer" do
      coalescing = FakeTurnExecutor.new(collect: "t-door")
      handler = described_class.new(profiles: profiles, session_store: session_store,
                                    task_store: task_store, executor: coalescing, inbound_log: log)
      session_store.create(id: "s1")
      cmd = Insika::Command.build(:send_message, payload(event_id: "wamid.9", session_id: "s1"),
                                  transport: :"channel:relay")

      first = handler.call(cmd)
      expect(first).to eq({ task_id: "t-door", merged: true })
      expect(handler.call(cmd)).to eq({ task_id: "t-door", duplicate: true })
      expect(coalescing.asked.count { |door, _s, _t| door == :collect }).to eq(1)
    end
  end

  describe "RFC-0033 — the contact hook (C6/C8)" do
    def declared(over = {})
      Insika::AgentProfile.build(
        id: "sales", model: "gpt",
        followup: { "arm" => "schedule",
                    "policy" => { "cancel_keywords" => ["não quero mais contato"] } }.merge(over)
      )
    end

    def send_msg(**over)
      handler.call(Insika::Command.build(:send_message, payload(**over), tenant: "acme"))
    end

    it "is a no-op with no profile declaration (byte-parity)" do
      session_store.create(id: "s1")
      send_msg(customer: "c-1", session_id: "s1")
      expect(contact_store.get(tenant: "acme", customer: "c-1")).to be_nil
    end

    it "is a no-op with contact_store nil" do
      plain = described_class.new(profiles: profiles, session_store: session_store,
                                  task_store: task_store, executor: executor)
      profiles["sales"] = declared
      session_store.create(id: "s1")
      plain.call(Insika::Command.build(:send_message, payload(customer: "c-1", session_id: "s1"),
                                       tenant: "acme"))
      expect(contact_store.get(tenant: "acme", customer: "c-1")).to be_nil
    end

    it "runs AFTER validation: a refused message never touches contact state (review fix)" do
      profiles["sales"] = declared
      session_store.create(id: "s1")
      # empty body -> ValidationError below, and the hook must not run
      expect do
        handler.call(Insika::Command.build(:send_message,
                                           payload(customer: "c-1", message: "", session_id: "s1"),
                                           tenant: "acme"))
      end.to raise_error(Insika::ValidationError)
      expect(contact_store.get(tenant: "acme", customer: "c-1")).to be_nil
    end

    it "runs AFTER the dedup check: a redelivered event does not touch contact twice (review fix)" do
      profiles["sales"] = declared
      log = Insika::InboundLog.new(store: backend)
      handler = described_class.new(profiles: profiles, session_store: session_store,
                                    task_store: task_store, executor: executor,
                                    contact_store: contact_store, followup_store: followup_store,
                                    inbound_log: log, store: backend)
      session_store.create(id: "s1")
      cmd = Insika::Command.build(:send_message,
                                  payload(customer: "c-1", event_id: "wamid.1", session_id: "s1"),
                                  tenant: "acme", transport: :"channel:relay")
      handler.call(cmd)
      handler.call(cmd)
      cell = contact_store.get(tenant: "acme", customer: "c-1")
      expect(cell).not_to be_nil
      expect(contact_store.cells.size).to eq(1) # one write, not two
    end

    it "a customer message sets granted (a tagged conversation opens the cell)" do
      profiles["sales"] = declared
      session_store.create(id: "s1")
      send_msg(customer: "c-1", session_id: "s1")
      cell = contact_store.get(tenant: "acme", customer: "c-1")
      expect(cell.state).to eq("granted")
      expect(cell.sends_without_reply).to eq(0)
    end

    it "a keyword match revokes + cancels the pending records in ONE transaction" do
      profiles["sales"] = declared
      followup_store.create(tenant: "acme", agent: "sales", customer: "c-1", session_id: "s1",
                            at: Time.now.utc + 3600, reason: "pix pending", arm: "schedule",
                            id: "k", now: Time.now.utc)
      session_store.create(id: "s1")

      send_msg(customer: "c-1", message: "NÃO quero mais contato, obrigada", session_id: "s1")

      expect(contact_store.get(tenant: "acme", customer: "c-1").state).to eq("revoked")
      expect(followup_store.find("k").status).to eq("cancelled")
    end

    it "an origin: 'engine' message changes nothing (only a real customer speaks)" do
      profiles["sales"] = declared
      session_store.create(id: "s1")
      send_msg(customer: "c-1", origin: "engine", session_id: "s1")
      expect(contact_store.get(tenant: "acme", customer: "c-1")).to be_nil
    end

    it "an engine-composed line QUOTING the keyword does not revoke (review fix — only the customer's own words act)" do
      profiles["sales"] = declared
      followup_store.create(tenant: "acme", agent: "sales", customer: "c-1", session_id: "s1",
                            at: Time.now.utc + 3600, reason: "pix pending", arm: "schedule",
                            id: "k", now: Time.now.utc)
      session_store.create(id: "s1")
      send_msg(customer: "c-1", message: "a cliente disse \"não quero mais contato\"",
               origin: "engine", session_id: "s1")
      expect(contact_store.get(tenant: "acme", customer: "c-1")).to be_nil
      expect(followup_store.find("k").status).to eq("pending")
    end

    it "the keyword revoke commits in ONE transaction on the shared backend (D2)" do
      profiles["sales"] = declared
      followup_store.create(tenant: "acme", agent: "sales", customer: "c-1", session_id: "s1",
                            at: Time.now.utc + 3600, reason: "pix pending", arm: "schedule",
                            id: "k", now: Time.now.utc)
      session_store.create(id: "s1")

      # a raising FALLING store on the shared backend rolls back the whole
      # pair — the cell is never left revoked with pending records alive
      flaky = Class.new do
        def initialize(real) = @real = real
        def transaction(&blk) = @real.transaction(&blk)
        def method_missing(...) = @real.public_send(...)
        def respond_to_missing?(*) = true
      end.new(backend)
      handler = described_class.new(profiles: profiles, session_store: session_store,
                                    task_store: task_store, executor: executor,
                                    contact_store: contact_store,
                                    followup_store: followup_store, store: flaky)

      send_msg = -> { handler.call(Insika::Command.build(:send_message,
                                                         payload(customer: "c-1",
                                                                 message: "NÃO quero mais contato",
                                                                 session_id: "s1"),
                                                         tenant: "acme")) }
      expect(send_msg).not_to raise_error
      expect(contact_store.get(tenant: "acme", customer: "c-1").state).to eq("revoked")
      expect(followup_store.find("k").status).to eq("cancelled")
    end

    it "refuses the engine-reserved origin 'scheduled' at the edge (C8)" do
      profiles["sales"] = declared
      session_store.create(id: "s1")
      expect { send_msg(origin: "scheduled", session_id: "s1") }
        .to raise_error(Insika::ValidationError, /engine-reserved/)
      expect(task_store.each_id.to_a).to be_empty
    end
  end
end
