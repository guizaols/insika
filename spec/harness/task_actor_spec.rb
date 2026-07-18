# frozen_string_literal: true

require "spec_helper"

RSpec.describe Harness::TaskActor do
  it "rejects a message outside the enum" do
    Sync do
      actor = described_class.new(task_id: "t")
      expect { actor.post(:bogus) }.to raise_error(ArgumentError)
    end
  end

  it "accepts the Phase 2 messages (approval/pause/resume/timeout/heartbeat)" do
    Sync do
      actor = described_class.new(task_id: "t")
      %i[approval pause resume timeout heartbeat].each do |m|
        expect { actor.post(m) }.not_to raise_error
      end
    end
  end

  it "drain! raises CancelledError after post(:cancel)" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:cancel)
      expect { actor.drain! }.to raise_error(Harness::CancelledError)
    end
  end

  it "accumulates :user_message (reserved) without raising" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:user_message, "oi")
      actor.drain!
      expect(actor.pending_user_messages).to eq(["oi"])
    end
  end

  it "empty drain! returns without blocking" do
    Sync do
      actor = described_class.new(task_id: "t")
      expect(actor.drain!).to be_nil
    end
  end

  it "drain! accumulates user_message AND raises the cancel (order preserved)" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:user_message, "antes")
      actor.post(:cancel)
      expect { actor.drain! }.to raise_error(Harness::CancelledError)
      expect(actor.pending_user_messages).to eq(["antes"])
    end
  end

  it "run executes the block in a fiber and returns an Async::Task" do
    Sync do
      actor = described_class.new(task_id: "t")
      ran = false
      handle = actor.run { ran = true }
      actor.wait
      expect(ran).to be(true)
      expect(handle).to be_a(Async::Task)
    end
  end

  # --- Phase 2: full mailbox + suspension ---------------------------------

  it "drain! sets pause_requested? on :pause and counts :heartbeat" do
    Sync do
      actor = described_class.new(task_id: "t")
      actor.post(:pause)
      actor.post(:heartbeat)
      actor.post(:heartbeat)
      actor.drain!
      expect(actor.pause_requested?).to be(true)
      expect(actor.heartbeats).to eq(2)
    end
  end

  it "await returns [:resume, nil] when :resume is posted" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      result = nil
      waiter = top.async { result = actor.await(reason: :paused) }
      top.sleep(0.01)
      actor.post(:resume)
      waiter.wait
      expect(result).to eq([:resume, nil])
      expect(actor.pause_requested?).to be(false) # cleared upon entering await
    end
  end

  it "await returns [:approval, decision] preserving the payload" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      result = nil
      waiter = top.async { result = actor.await(reason: :waiting) }
      top.sleep(0.01)
      actor.post(:approval, "approved")
      waiter.wait
      expect(result).to eq([:approval, "approved"])
    end
  end

  it "discards an orphan resolution in drain! (does NOT auto-resolve a future await)" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      actor.post(:resume) # orphan: arrives with no pending suspension
      actor.drain!        # discards (does not buffer)
      resolved = false
      waiter = top.async { actor.await(reason: :paused); resolved = true }
      top.sleep(0.02)
      expect(resolved).to be(false) # the discarded orphan did not resolve this await
      actor.post(:resume)           # only a REAL :resume resolves
      waiter.wait
      expect(resolved).to be(true)
    end
  end

  it "await ignores :pause received during the wait (does not re-arm pause)" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      waiter = top.async { actor.await(reason: :paused) }
      top.sleep(0.01)
      actor.post(:pause)  # redundant pause during the wait
      actor.post(:resume)
      waiter.wait
      expect(actor.pause_requested?).to be(false) # did not re-arm -> no re-pause
    end
  end

  it "await raises CancelledError when :cancel arrives during the wait" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      raised = nil
      waiter = top.async do
        actor.await(reason: :paused)
      rescue Harness::CancelledError => e
        raised = e
      end
      top.sleep(0.01)
      actor.post(:cancel)
      waiter.wait
      expect(raised).to be_a(Harness::CancelledError)
    end
  end

  it "await raises TimeoutError on :timeout (with stage)" do
    Sync do |top|
      actor = described_class.new(task_id: "t")
      raised = nil
      waiter = top.async do
        actor.await(reason: :approval_timeout)
      rescue Harness::TimeoutError => e
        raised = e
      end
      top.sleep(0.01)
      actor.post(:timeout, :approval_timeout)
      waiter.wait
      expect(raised).to be_a(Harness::TimeoutError)
      expect(raised.stage).to eq(:approval_timeout)
    end
  end
end
