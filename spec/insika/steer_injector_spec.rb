# frozen_string_literal: true

require "spec_helper"
require "async"

# RFC-0015 §5.2 — the tool-batch boundary. Every case here is about WHERE the message
# lands, because the wrong place is not a cosmetic problem: a `user` message between two
# tool results is rejected outright by Anthropic and tolerated by OpenAI, so a boundary
# that is off by one fails on one provider and silently corrupts the other.
RSpec.describe Insika::SteerInjector do
  let(:chat) { FakeChat.new }
  let(:actor) { Insika::TaskActor.new(task_id: "t1", parent: Async::Task.current) }
  let(:events) { [] }

  def policy(steer_join: nil)
    Insika::QueuePolicy.resolve(
      Insika::AgentProfile.build(id: "a", model: "m",
                                 limits: { queue_mode: "steer", steer_join: steer_join }.compact)
    )
  end

  def injector(steer_join: nil)
    described_class.new(chat: chat, actor: actor, policy: policy(steer_join: steer_join),
                        emit: ->(type, data) { events << [type, data] })
  end

  # The gem's sequence for a batch of N calls, as the real Chat runs it.
  def run_batch(inj, ids, halt: nil)
    calls = ids.to_h { |id| [id, FakeChat::ToolCall.new("search", {}, id)] }
    inj.message_ended(FakeChat::Message.new("assistant", "vou buscar", calls))
    ids.each do |id|
      inj.tool_result(id == halt ? RubyLLM::Tool::Halt.new("done") : "ok")
      inj.message_ended(FakeChat::Message.new("tool", "ok", nil))
    end
  end

  def user_messages = chat.messages.select { |m| m[:role] == :user }.map { |m| m[:content] }

  it "appends after the LAST result of the batch, never between results" do
    Sync do
      inj = injector
      actor.post(:user_message, "1234567")

      inj.message_ended(FakeChat::Message.new("assistant", "vou buscar",
                                              { "c1" => 1, "c2" => 2 }))
      inj.tool_result("ok")
      inj.message_ended(FakeChat::Message.new("tool", "ok", nil))
      expect(user_messages).to be_empty # one result in, one to go: still not a boundary

      inj.tool_result("ok")
      inj.message_ended(FakeChat::Message.new("tool", "ok", nil))
      expect(user_messages).to eq(["1234567"])
    end
  end

  it "emits :turn_steered with counts and no content" do
    Sync do
      inj = injector
      actor.post(:user_message, "1234567")
      run_batch(inj, %w[c1])

      type, data = events.first
      expect(type).to eq(:turn_steered)
      expect(data).to eq({ count: 1, total: 1 })
    end
  end

  it "absorbs several messages in arrival order, in one boundary" do
    Sync do
      inj = injector
      actor.post(:user_message, "1234567")
      actor.post(:user_message, "aliás, o outro pedido")
      run_batch(inj, %w[c1])

      expect(user_messages).to eq(["1234567", "aliás, o outro pedido"])
      expect(inj.injected).to eq(2)
    end
  end

  it "does nothing at all when no message arrived (the common case)" do
    Sync do
      inj = injector
      run_batch(inj, %w[c1 c2])

      expect(chat.messages).to be_empty
      expect(events).to be_empty
    end
  end

  it "a batch that ends in halt_when injects NOTHING and leaves the message in the mailbox" do
    Sync do
      inj = injector
      actor.post(:user_message, "1234567")
      run_batch(inj, %w[c1], halt: "c1")

      expect(user_messages).to be_empty
      expect(events).to be_empty
      # Still there for the Executor to release as a follow-up turn — a halted turn has
      # no next model step, so an appended message would never be answered.
      expect(actor.take_user_messages!).to eq(["1234567"])
    end
  end

  it "an assistant message with NO tool call is not a batch and opens nothing" do
    Sync do
      inj = injector
      actor.post(:user_message, "1234567")
      inj.message_ended(FakeChat::Message.new("assistant", "achei", nil))
      # A stray tool message with no batch open must not count as a boundary.
      inj.message_ended(FakeChat::Message.new("tool", "ok", nil))

      expect(user_messages).to be_empty
    end
  end

  it "counts each batch on its own: a second round steers again" do
    Sync do
      inj = injector
      actor.post(:user_message, "primeiro")
      run_batch(inj, %w[c1])
      actor.post(:user_message, "segundo")
      run_batch(inj, %w[c1 c2])

      expect(user_messages).to eq(%w[primeiro segundo])
      expect(inj.injected).to eq(2)
    end
  end

  it "steer_join frames the text; a stray % in what the customer typed does not raise" do
    Sync do
      inj = injector(steer_join: "the customer just added: %{message}")
      actor.post(:user_message, "50% de desconto?")
      run_batch(inj, %w[c1])

      expect(user_messages).to eq(["the customer just added: 50% de desconto?"])
    end
  end
end
