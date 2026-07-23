# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "socket"
require "fileutils"
require "tmpdir"

# E2E smoke (task 26 §7, phase completion criterion — doc 00 §6): boots Falcon
# + mocked RubyLLM (shim), POST send_message with session_id, kills the process in
# the MIDDLE of the turn (kill -9), boots again and checks the task RESUMED from the
# checkpoint. Runs WITHOUT an API key. Tag :smoke.
RSpec.describe "smoke E2E: kill -9 mid-turn + reboot + resume", :smoke do
  def repo_root = File.expand_path("../..", __dir__)
  def smoke_dir = File.join(repo_root, "spec", "support", "smoke")

  # --- process/HTTP infra (stdlib) ----------------------------------
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def spawn_server(port:, db:, marker:, mode:, recovery_marker: nil, approval: false)
    env = {
      "SMOKE_DB" => db, "SMOKE_TURN_STARTED" => marker,
      "SMOKE_BIND" => "http://127.0.0.1:#{port}",
      "RUBYOPT" => "-I#{File.join(smoke_dir, "shims")}",
      "BUNDLE_GEMFILE" => File.join(repo_root, "Gemfile")
    }
    env["SMOKE_MODE"] = mode if mode
    env["SMOKE_RECOVERY_DONE"] = recovery_marker if recovery_marker
    env["SMOKE_APPROVAL"] = "1" if approval
    Process.spawn(env, "bundle", "exec", "ruby", File.join(smoke_dir, "serve.rb"),
                  out: File.join(File.dirname(db), "serve_#{mode || "trava"}.log"),
                  err: %i[child out])
  end

  def wait_until(timeout:, msg:)
    deadline = now + timeout
    loop do
      result = yield
      return result if result
      raise "timeout esperando: #{msg}" if now > deadline

      sleep 0.1
    end
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def http(port, method, path, body: nil)
    uri = URI("http://127.0.0.1:#{port}#{path}")
    req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
    req.body = body if body
    req["content-type"] = "application/json" if body
    Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) { |h| h.request(req) }
  rescue StandardError
    nil # server still booting / between reboots
  end

  def wait_alive(port)
    wait_until(timeout: 25, msg: "server to respond") do
      resp = http(port, :get, "/v1/tasks/none")
      resp && resp.code == "404"
    end
  end

  it "survives kill -9 and resumes from the checkpoint (task :completed, 2 executions, intact transcript)" do
    Dir.mktmpdir("harness-smoke") do |dir|
      db = File.join(dir, "smoke.sqlite3")
      marker = File.join(dir, "turn_started")
      port = free_port
      pid1 = spawn_server(port: port, db: db, marker: marker, mode: nil) # blocking mode
      pid2 = nil

      begin
        wait_alive(port)

        # create session
        resp = http(port, :post, "/v1/sessions", body: "{}")
        expect(resp.code).to eq("201")
        session_id = JSON.parse(resp.body)["session"]["id"]

        # dispatch the turn via the generic route (immediate 202 — task_id survives the kill)
        resp = http(port, :post, "/v1/commands/send_message",
                    body: JSON.generate(agent: "smoke", message: "oi", session_id: session_id))
        expect(resp.code).to eq("202")
        task_id = JSON.parse(resp.body)["task_id"]
        expect(task_id).not_to be_nil

        # the turn is in the middle of stage 6 (blocked): marker written by the shim.
        # NB (L4): the POST above already closed the connection (Net::HTTP finishes at
        # the end of the block). The marker appearing AFTER that proves the turn
        # survived the disconnect — i.e., the supervisor was created above the request
        # at the real reactor boundary (async-http). If it were a child of the
        # connection, it would die here and the marker would never arrive.
        wait_until(timeout: 15, msg: "turno iniciar (marker)") { File.exist?(marker) }

        # kill -9: non-cooperative death; the task is left :running orphaned in SQLite
        Process.kill(9, pid1)
        Process.wait(pid1)
        pid1 = nil

        # reboot in "complete" mode: the Boot runs Recovery BEFORE the listen ->
        # finds the orphan with a checkpoint -> resume_task -> completes.
        pid2 = spawn_server(port: port, db: db, marker: marker, mode: "complete")
        wait_alive(port)

        # the task was resumed and completed
        task = wait_until(timeout: 20, msg: "task to complete post-reboot") do
          resp = http(port, :get, "/v1/tasks/#{task_id}")
          next unless resp && resp.code == "200"

          t = JSON.parse(resp.body)["task"]
          t if t["status"] == "completed"
        end

        # attempt 1 (interrupted) + attempt 2 (completed) — doc 02 §3
        expect(task["executions"].length).to eq(2)

        # persisted transcript: user message + assistant reply
        resp = http(port, :get, "/v1/sessions/#{session_id}")
        roles = JSON.parse(resp.body)["session"]["messages"].map { |m| m["role"] }
        expect(roles).to include("user", "assistant")
      ensure
        [pid1, pid2].compact.each do |pid|
          Process.kill(9, pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end
  end

  it "recovery runs BEFORE the listen (the 1st HTTP response implies recovery is done)" do
    Dir.mktmpdir("harness-smoke") do |dir|
      db = File.join(dir, "smoke.sqlite3")
      recovery_marker = File.join(dir, "recovery_done")
      port = free_port
      pid = spawn_server(port: port, db: db, marker: File.join(dir, "m"),
                         mode: "complete", recovery_marker: recovery_marker)
      begin
        wait_alive(port) # first successful HTTP response
        # the listen is the last step of Boot: if the server responded, recovery
        # (marker) already finished — by construction, it never serves before recovery.
        expect(File.exist?(recovery_marker)).to be(true)
      ensure
        begin
          Process.kill(9, pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end
  end

  # Slice A criterion (P2, 00-overview): the `approval` tool suspends the turn in
  # :waiting; the operator sees the pending action and approves via HTTP -> the tool
  # executes and the turn completes. (The CRASH-SAFE path — post-kill re-execution
  # using the durable PendingAction — is covered by
  # spec/insika/tool_envelope_approval_spec at the integration level. See task 14's
  # Notes about the :waiting-turn recovery limitation at boot.)
  it "approval: tool suspends in :waiting; operator approves via HTTP -> turn completes", :smoke do
    Dir.mktmpdir("harness-smoke-appr") do |dir|
      db = File.join(dir, "s.sqlite3")
      port = free_port
      pid = spawn_server(port: port, db: db, marker: File.join(dir, "m"), mode: nil, approval: true)
      begin
        wait_alive(port)
        sid = JSON.parse(http(port, :post, "/v1/sessions", body: "{}").body)["session"]["id"]
        resp = http(port, :post, "/v1/commands/send_message",
                    body: JSON.generate(agent: "approver", message: "cobra", session_id: sid))
        task_id = JSON.parse(resp.body)["task_id"]

        # the tool tripped the gate -> task :waiting with a PendingAction (visible in the read)
        pending = wait_until(timeout: 15, msg: "task suspender em :waiting") do
          t = JSON.parse(http(port, :get, "/v1/tasks/#{task_id}").body)
          pa = t["pending_actions"]&.first
          pa if t["task"]["status"] == "waiting" && pa
        end
        expect(pending["tool"]).to eq("charge")

        # operator approves via HTTP -> the tool executes and the turn completes
        approve = http(port, :post, "/v1/commands/approve_action",
                       body: JSON.generate(pending_id: pending["id"], decision: "approved"))
        expect(approve.code).to eq("200")

        task = wait_until(timeout: 20, msg: "complete post-approval") do
          t = JSON.parse(http(port, :get, "/v1/tasks/#{task_id}").body)["task"]
          t if t["status"] == "completed"
        end
        expect(task["status"]).to eq("completed")
        msgs = JSON.parse(http(port, :get, "/v1/sessions/#{sid}").body)["session"]["messages"]
        expect(msgs.map { |m| m["content"] }.join).to include("charged")
      ensure
        begin
          Process.kill(9, pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end
  end
end
