# frozen_string_literal: true

require "spec_helper"
require "async"

# the terminal hook. A turn that came in through a Shape B channel
# writes its answer to the outbox and hands it over; every other turn does nothing,
# and "every other turn" includes ones on the SAME session, which is the part worth
# a test rather than a comment.
RSpec.describe "Insika::Executor channel delivery" do
  # Shape B channel: remembers what it was asked to send. `progressive` (
  # C2) is the channel's own delivery policy; the executor asks.
  class SpyChannel
    attr_reader :sent
    attr_accessor :progressive

    def initialize = (@sent = [])
    def progressive? = !!@progressive

    def deliver(payload, to:, delivery_id: nil)
      @sent << { payload: payload, to: to, delivery_id: delivery_id }
      200
    end
  end

  let(:backend) { Insika::Stores::Memory.new }
  let(:session_store) { Insika::SessionStore.new(store: backend) }
  let(:task_store) { Insika::TaskStore.new(store: backend) }
  let(:checkpoint_store) { Insika::CheckpointStore.new(store: backend) }
  let(:outbox) { Insika::OutboxStore.new(store: backend) }
  let(:event_stream) { SpyEventStream.new }
  let(:channel) { SpyChannel.new }
  let(:channels) { Insika::ChannelRegistry.new.tap { |r| r.register("relay", channel) } }
  let(:profile) { Insika::AgentProfile.build(id: "support", model: "gpt", base_prompt: "SUPPORT") }

  let(:delivery) do
    Insika::ChannelDelivery.new(channels: channels, outbox: outbox, session_store: session_store,
                                event_stream: event_stream, sleeper: ->(_s) {})
  end

  def executor(channel_delivery: delivery)
    Insika::Executor.new(
      context_builder: FakeContextBuilder.new, policy_engine: NullPolicyEngine.new,
      middleware: PassthroughMiddleware.new, hooks: NullHooks.new,
      tool_registry: FakeToolRegistry.new, skill_catalog: Insika::SkillCatalog.new([]),
      profiles: { "support" => profile },
      session_store: session_store, task_store: task_store, checkpoint_store: checkpoint_store,
      event_stream: event_stream, channel_delivery: channel_delivery
    )
  end

  # A turn on the relay session, tagged with whatever transport the caller says.
  def run_turn(transport:, answer: "seu pedido saiu hoje", session_id: "relay:551",
               progressive: false, chat: nil)
    session_store.find(session_id) ||
      session_store.create(id: session_id, vars: { "channel" => "relay", "external_id" => "551" })
    channel.progressive = progressive
    command = Insika::Command.build(:send_message, { agent: "support", message: "cadê meu pedido?",
                                                     session_id: session_id },
                                    transport: transport).to_h
    task = task_store.create(command: command, session_id: session_id)

    exec = executor
    allow(exec).to receive(:create_chat) do
      chat || FakeChat.new.tap { |c| c.final_content = answer }
    end
    Sync { exec.spawn(task, profile: profile) }
    task
  end

  it "delivers the answer of a turn that came in through the channel" do
    task = run_turn(transport: :"channel:relay")

    expect(channel.sent.size).to eq(1)
    sent = channel.sent.first
    expect(sent[:to]).to eq("551")
    expect(sent[:payload]).to eq("session_id" => "relay:551", "task_id" => task.id,
                                 "content" => "seu pedido saiu hoje")
    expect(sent[:delivery_id]).to eq(outbox.find(sent[:delivery_id]).id)
  end

  it "marks the outbox record delivered and says so on the event stream" do
    run_turn(transport: :"channel:relay")

    record = outbox.find(channel.sent.first[:delivery_id])
    expect(record.status).to eq(:delivered)
    expect(event_stream.events.map(&:type)).to include(:channel_delivered)
  end

  # The discriminator is the TURN's transport, not the session's channel. A session
  # belongs to the relay forever, but a message an operator types into the Studio
  # playground against that same conversation must not reach the customer — human
  # handoff is not a product feature, and this would be a surprising way to get one.
  it "delivers NOTHING for a turn on the same session that arrived another way" do
    run_turn(transport: :http)

    expect(channel.sent).to be_empty
    expect(outbox.pending).to be_empty
  end

  it "delivers nothing for a channel that is not registered" do
    run_turn(transport: :"channel:slack")

    expect(channel.sent).to be_empty
    expect(outbox.pending).to be_empty
  end

  it "is inert when the deployment wires no channel delivery at all" do
    exec = executor(channel_delivery: nil)
    session_store.create(id: "relay:551", vars: { "channel" => "relay", "external_id" => "551" })
    command = Insika::Command.build(:send_message, { agent: "support", message: "oi", session_id: "relay:551" },
                                    transport: :"channel:relay").to_h
    task = task_store.create(command: command, session_id: "relay:551")
    allow(exec).to receive(:create_chat) { FakeChat.new.tap { |c| c.final_content = "oi!" } }

    expect { Sync { exec.spawn(task, profile: profile) } }.not_to raise_error
    expect(task_store.find(task.id).status).to eq(:completed)
  end

  # The turn is committed and durable before any of this runs. A third party being
  # down is not a reason to fail a turn that already answered correctly.
  it "never re-fails a committed turn when the delivery blows up" do
    exploding = Class.new do
      def progressive?(_channel_id) = false
      def record_balloons(**) = raise(Insika::StoreError, "outbox unavailable")
    end.new
    exec = executor(channel_delivery: exploding)
    session_store.create(id: "relay:551", vars: { "channel" => "relay", "external_id" => "551" })
    command = Insika::Command.build(:send_message, { agent: "support", message: "oi", session_id: "relay:551" },
                                    transport: :"channel:relay").to_h
    task = task_store.create(command: command, session_id: "relay:551")
    allow(exec).to receive(:create_chat) { FakeChat.new.tap { |c| c.final_content = "oi!" } }

    Sync { exec.spawn(task, profile: profile) }
    expect(task_store.find(task.id).status).to eq(:completed)
  end

  # a progressive relay turns the answer into N outbox rows and
  # dispatches them IN ORDER, before the turn is even observed completed (the
  # dispatch is inline when not serving).
  describe "progressive delivery " do
    it "E1: a two-paragraph answer is two POSTs, first paragraph first, both before :task_completed" do
      task = run_turn(transport: :"channel:relay", progressive: true,
                      answer: "Para um.\n\nPara dois.")

      expect(channel.sent.size).to eq(2)
      expect(channel.sent.map { |s| s[:payload]["content"] }).to eq(["Para um.", "Para dois."])
      expect(channel.sent.first[:payload]).to include("index" => 0, "final" => false)
      expect(channel.sent.last[:payload]).to include("index" => 1, "final" => true)
      expect(channel.sent.first[:payload]["task_id"]).to eq(task.id.to_s)

      completed = event_stream.events.find { |e| e.type == :task_completed }
      expect(completed).not_to be_nil
      expect(completed.data[:content]).to eq("Para um.\n\nPara dois.") # :content stays WHOLE
    end

    # D1: balloons are cut from turn_answer AFTER hooks, so narration that preceded
    # a tool call is never a balloon — it was not the answer.
    it "E1 discard: loop narration before a tool call never becomes a balloon" do
      chat = FakeChat.new
      chat.final_content = "Achei.\n\nPronto."
      chat.script = proc do
        emit_chunk("Deixa eu buscar.")
        fire_tool_call(name: "search")
      end
      run_turn(transport: :"channel:relay", progressive: true, chat: chat)

      contents = channel.sent.map { |s| s[:payload]["content"] }
      expect(contents).to eq(["Achei.", "Pronto."])
      expect(contents.join).not_to include("Deixa eu buscar.")
      # the narration WAS the intermediate stream — the operator still sees it
      expect(event_stream.events.map(&:type)).to include(:intermediate)
    end

    it ":at_end (the default) is ONE POST, whole text, no index/final" do
      run_turn(transport: :"channel:relay", answer: "Para um.\n\nPara dois.")

      expect(channel.sent.size).to eq(1)
      expect(channel.sent.first[:payload]["content"]).to eq("Para um.\n\nPara dois.")
      expect(channel.sent.first[:payload]).not_to have_key("index")
      expect(channel.sent.first[:payload]).not_to have_key("final")
    end

    it "a progressive turn that split to one balloon is indistinguishable from at_end" do
      run_turn(transport: :"channel:relay", progressive: true, answer: "oi")

      expect(channel.sent.size).to eq(1)
      expect(channel.sent.first[:payload]["content"]).to eq("oi")
      expect(channel.sent.first[:payload]).not_to have_key("index")
      expect(channel.sent.first[:payload]).not_to have_key("final")
    end
  end

  # steering with the buffer OFF, in-process. A progressive relay
  # whose agent steers — the balloons are the POST-steer answer, never the
  # narration that preceded the tool call.
  describe "steer + progressive " do
    def stop_serving(executor)
      executor.stop_session_actors
      executor.instance_variable_get(:@supervisor)&.stop
    end

    it "balloons are the post-steer answer, never the pre-steer narration" do
      steering = Insika::AgentProfile.build(id: "support", model: "gpt", base_prompt: "SUPPORT",
                                            limits: { queue_mode: "steer" })
      exec = executor
      exec.supervised = true
      session_store.create(id: "relay:551", vars: { "channel" => "relay", "external_id" => "551" })
      channel.progressive = true

      chat = FakeChat.new
      chat.final_content = "Certo, o outro.\n\nMandei."
      chat.script = proc do
        emit_chunk("Vou buscar o primeiro.")
        fire_tool_call(name: "search")
        Async::Task.current.sleep(0.05) # the steered message lands while the tool is in flight
        fire_tool_result("ok")
        fire_tool_result_message("ok")
      end
      allow(exec).to receive(:create_chat).and_return(chat)

      Sync do |top|
        command = Insika::Command.build(:send_message,
                                        { agent: "support", message: "quero o primeiro",
                                          session_id: "relay:551" }, transport: :"channel:relay")
        task = task_store.create(command: command.to_h, session_id: "relay:551")
        exec.spawn_in_session(task, profile: steering)
        top.sleep(0.02)

        expect(exec.steer_into_running("relay:551", "não, o outro", profile: steering)).to eq(task.id)

        200.times do
          break if channel.sent.size >= 2
          top.sleep(0.01)
        end
        stop_serving(exec)
      end

      contents = channel.sent.map { |s| s[:payload]["content"] }
      expect(contents).to eq(["Certo, o outro.", "Mandei."])
      expect(contents.join).not_to include("Vou buscar")
      expect(channel.sent.first[:payload]).to include("index" => 0, "final" => false)
      expect(event_stream.types).to include(:turn_steered)
    end
  end

  # first_balloon_ms — inbound -> first outbox row, always measured
  # on a channel turn, persisted onto the task record.
  describe "first_balloon_ms " do
    it "a channel turn persists timing to the task record; first_balloon_ms < the turn's wall clock" do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      task = run_turn(transport: :"channel:relay", progressive: true,
                      answer: "Para um.\n\nPara dois.")
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

      stored = task_store.find(task.id)
      expect(stored.timing).to be_a(Hash)
      expect(stored.timing["first_balloon_ms"]).to be_a(Numeric)
      expect(stored.timing["first_balloon_ms"]).to be < elapsed_ms
    end

    it "a one-balloon :at_end turn still stamps it — the flush happened, even if n=1" do
      task = run_turn(transport: :"channel:relay", answer: "oi")

      expect(task_store.find(task.id).timing["first_balloon_ms"]).to be_a(Numeric)
    end

    it "a NON-channel turn with the flag off leaves timing absent (no balloon, no clock)" do
      task = run_turn(transport: :http)

      expect(task_store.find(task.id).timing).to be_nil
    end

    it "the terminal event carries first_balloon_ms for a channel turn, even with the flag off" do
      run_turn(transport: :"channel:relay", answer: "oi")

      completed = event_stream.events.find { |e| e.type == :task_completed }
      expect(completed.data[:timing]).to include(:first_balloon_ms)
    end
  end

  describe "recover_channel_deliveries (boot)" do
    it "re-drives a reply a dead process recorded and never claimed" do
      task = task_store.create(command: { "type" => "send_message" }, session_id: "relay:551")
      session_store.create(id: "relay:551", vars: { "channel" => "relay", "external_id" => "551" })
      record = outbox.create(channel: "relay", to: "551", task_id: task.id, session_id: "relay:551",
                             payload: { "content" => "pronto" })

      expect(executor.recover_channel_deliveries).to eq(dispatched: [record.id])
      expect(channel.sent.size).to eq(1)
    end

    it "reports nothing when no channel delivery is wired" do
      expect(executor(channel_delivery: nil).recover_channel_deliveries).to eq(dispatched: [])
    end
  end
end
