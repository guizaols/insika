# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require "socket"
require "fileutils"
require "tmpdir"

# Smoke E2E (task 26 §7, critério de conclusão da fase — doc 00 §6): sobe Falcon
# + RubyLLM mockado (shim), POST send_message com session_id, mata o processo no
# MEIO do turno (kill -9), sobe de novo e verifica a task RETOMADA do checkpoint.
# Roda SEM API key. Tag :smoke.
RSpec.describe "smoke E2E: kill -9 no meio do turno + reboot + retomada", :smoke do
  def repo_root = File.expand_path("../..", __dir__)
  def smoke_dir = File.join(repo_root, "spec", "support", "smoke")

  # --- infra de processo/HTTP (stdlib) ----------------------------------
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def spawn_server(port:, db:, marker:, mode:, recovery_marker: nil)
    env = {
      "SMOKE_DB" => db, "SMOKE_TURN_STARTED" => marker,
      "SMOKE_BIND" => "http://127.0.0.1:#{port}",
      "RUBYOPT" => "-I#{File.join(smoke_dir, "shims")}",
      "BUNDLE_GEMFILE" => File.join(repo_root, "Gemfile")
    }
    env["SMOKE_MODE"] = mode if mode
    env["SMOKE_RECOVERY_DONE"] = recovery_marker if recovery_marker
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
    nil # servidor ainda subindo / entre reboots
  end

  def wait_alive(port)
    wait_until(timeout: 25, msg: "servidor responder") do
      resp = http(port, :get, "/v1/tasks/none")
      resp && resp.code == "404"
    end
  end

  it "sobrevive ao kill -9 e retoma do checkpoint (task :completed, 2 executions, transcript íntegro)" do
    Dir.mktmpdir("harness-smoke") do |dir|
      db = File.join(dir, "smoke.sqlite3")
      marker = File.join(dir, "turn_started")
      port = free_port
      pid1 = spawn_server(port: port, db: db, marker: marker, mode: nil) # modo trava
      pid2 = nil

      begin
        wait_alive(port)

        # cria sessão
        resp = http(port, :post, "/v1/sessions", body: "{}")
        expect(resp.code).to eq("201")
        session_id = JSON.parse(resp.body)["session"]["id"]

        # despacha o turno via rota genérica (202 imediato — task_id sobrevive ao kill)
        resp = http(port, :post, "/v1/commands/send_message",
                    body: JSON.generate(agent: "smoke", message: "oi", session_id: session_id))
        expect(resp.code).to eq("202")
        task_id = JSON.parse(resp.body)["task_id"]
        expect(task_id).not_to be_nil

        # o turno está no meio do estágio 6 (trava): marker gravado pelo shim
        wait_until(timeout: 15, msg: "turno iniciar (marker)") { File.exist?(marker) }

        # kill -9: morte não-cooperativa; a task fica :running órfã no SQLite
        Process.kill(9, pid1)
        Process.wait(pid1)
        pid1 = nil

        # reboot em modo "completa": o Boot roda o Recovery ANTES do listen ->
        # acha a órfã com checkpoint -> resume_task -> conclui.
        pid2 = spawn_server(port: port, db: db, marker: marker, mode: "complete")
        wait_alive(port)

        # a task foi retomada e concluída
        task = wait_until(timeout: 20, msg: "task concluir pós-reboot") do
          resp = http(port, :get, "/v1/tasks/#{task_id}")
          next unless resp && resp.code == "200"

          t = JSON.parse(resp.body)["task"]
          t if t["status"] == "completed"
        end

        # attempt 1 (interrompida) + attempt 2 (concluída) — doc 02 §3
        expect(task["executions"].length).to eq(2)

        # transcript persistido: mensagem do usuário + resposta do assistant
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

  it "recovery roda ANTES do listen (a 1ª resposta HTTP implica recovery concluído)" do
    Dir.mktmpdir("harness-smoke") do |dir|
      db = File.join(dir, "smoke.sqlite3")
      recovery_marker = File.join(dir, "recovery_done")
      port = free_port
      pid = spawn_server(port: port, db: db, marker: File.join(dir, "m"),
                         mode: "complete", recovery_marker: recovery_marker)
      begin
        wait_alive(port) # primeira resposta HTTP bem-sucedida
        # o listen é o último passo do Boot: se o servidor respondeu, o recovery
        # (marker) já terminou — por construção, nunca serve antes do recovery.
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
end
