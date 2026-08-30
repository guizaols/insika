# frozen_string_literal: true

require "spec_helper"
require "async"
require "rack/urlmap"
require "rack/mock"
require_relative "../../lib/insika/server/rack_app"

# Embeddability. The engine was one PROGRAM, not one process: two
# graphs in the same Ruby process silently shared the LLM credentials and could
# not be told which store to use except through a process-wide environment
# variable. Neither failure raised — the second graph simply won, for both.
#
# These are the design's experiments, turned into the regression tests that keep
# the embed contract (docs/EMBEDDING.md) true:
#
# 1  two tenants, no key theft   — a graph asks on ITS OWN key
# 2  two graphs, two stores      — and neither one reads INSIKA_DB
# 3  the mounted app answers     — under a prefix, for its own graph
#
# 4 (drain reaches every graph) lives in shutdown_spec.rb, next to the rest of
# the signal path.
RSpec.describe "Insika.embed" do
  def embed(backend, key:, id: "support")
    Insika.embed(backend: backend) do
      agent id do
        model "deepseek-chat"
        provider :deepseek
        api_key key
        instructions "You are helpful."
      end
    end
  end

  # 1 — the assertion has to be the key ACTUALLY USED at call time, not the
  # config object: `RubyLLM.context` isolates the config, but the models registry
  # and any provider-level memoization inside the gem stay process-wide, so
  # comparing configs would prove nothing about the request. The provider's
  # Authorization header is the closest thing to the wire without a network call.
  describe ".1 — two tenants, one provider, no key theft" do
    before { skip "real ruby_llm gem not installed" unless defined?(RubyLLM::Context) }

    # The chat the Executor would send the turn on. `create_chat` is documented as
    # the ONLY point that touches the gem (executor.rb), which is why it is also
    # the only place had to change.
    def authorization_of(runtime)
      state = Struct.new(:session, :model_selection).new(nil, nil)
      chat = runtime.graph.executor.send(:create_chat, runtime.profile("support"), state)
      chat.instance_variable_get(:@provider).headers["Authorization"]
    end

    it "each graph asks on its own credentials — the later graph does not win for both" do
      a = embed(Insika::Stores::Memory.new, key: "TENANT-1").runtime
      b = embed(Insika::Stores::Memory.new, key: "TENANT-2").runtime

      expect(authorization_of(a)).to eq("Bearer TENANT-1")
      expect(authorization_of(b)).to eq("Bearer TENANT-2")
      # And built in the other order, the first graph is still itself: this is the
      # measurement that failed before, where B's key answered for A too.
      expect(authorization_of(a)).to eq("Bearer TENANT-1")
    end

    it "never mutates the process-wide config (embed contract)" do
      before_config = RubyLLM.config.deepseek_api_key
      embed(Insika::Stores::Memory.new, key: "TENANT-3").runtime
      expect(RubyLLM.config.deepseek_api_key).to eq(before_config)
    end

    it "the graph's own context is what the Executor holds" do
      runtime = embed(Insika::Stores::Memory.new, key: "TENANT-4").runtime
      expect(runtime.llm).to be_a(RubyLLM::Context)
      expect(runtime.graph.executor.instance_variable_get(:@llm)).to equal(runtime.llm)
    end

    # The risk, decided rather than left implied: an operator editing a provider
    # key in the Studio of an embedded graph must not reconfigure its neighbours.
    it "a runtime provider edit stays inside the graph" do
      a = embed(Insika::Stores::Memory.new, key: "TENANT-1").runtime
      b = embed(Insika::Stores::Memory.new, key: "TENANT-2").runtime

      a.component(:configurator).apply([{ "api" => "deepseek", "api_key" => "ROTATED" }])

      expect(authorization_of(a)).to eq("Bearer ROTATED")
      expect(authorization_of(b)).to eq("Bearer TENANT-2")
      expect(RubyLLM.config.deepseek_api_key).not_to eq("ROTATED")
    end
  end

  describe ".2 — two graphs, two stores" do
    it "a session created in one graph is invisible to the other" do
      a = embed(Insika::Stores::Memory.new, key: "k1").runtime
      b = embed(Insika::Stores::Memory.new, key: "k2").runtime

      a.graph.session_store.create(id: "s-1", vars: {})

      expect(a.graph.session_store.find("s-1")).not_to be_nil
      expect(b.graph.session_store.find("s-1")).to be_nil
      expect(a.graph.backend).not_to equal(b.graph.backend)
    end

    it "the injected backend wins over INSIKA_DB — ENV is a default, never a requirement" do
      previous = ENV["INSIKA_DB"]
      ENV["INSIKA_DB"] = File.join(Dir.tmpdir, "insika-embed-spec-must-not-be-opened.sqlite3")

      backend = Insika::Stores::Memory.new
      runtime = embed(backend, key: "k").runtime

      expect(runtime.graph.backend).to equal(backend)
      expect(runtime.graph).not_to be_durable
      expect(File.exist?(ENV.fetch("INSIKA_DB"))).to be false
    ensure
      previous.nil? ? ENV.delete("INSIKA_DB") : ENV["INSIKA_DB"] = previous
    end

    # is a front door over the SAME assembly, not a second route into the
    # engine (a single pipeline). If it ever grew one, the profile is
    # where the divergence would surface first.
    it "produces the same profile as Insika.agent { … } (parity)" do
      embedded = embed(Insika::Stores::Memory.new, key: "k").runtime.profile("support")
      plain = Insika.agent("support") do
        model "deepseek-chat"
        provider :deepseek
        instructions "You are helpful."
      end.profile

      expect(embedded.to_h).to eq(plain.to_h)
    end
  end

  describe ".3 — the mounted app answers under a prefix" do
    let(:backend) { Insika::Stores::Memory.new }
    let(:system) { embed(backend, key: "k") }
    let(:other) { embed(Insika::Stores::Memory.new, key: "k") }

    # The host's router — Rails' `mount` and Rack::URLMap do the same thing: move
    # the prefix into SCRIPT_NAME and leave PATH_INFO to the mounted app.
    def mounted(app) = Rack::URLMap.new("/ai" => app)

    def get(app, path, auth: "tok")
      env = Rack::MockRequest.env_for(path)
      env["HTTP_AUTHORIZATION"] = "Bearer #{auth}" if auth
      app.call(env)
    end

    it "serves /v1 under the mount point, and 404s outside it" do
      app = mounted(Insika::Server.rack_app(system, token: "tok"))

      status, = get(app, "/ai/v1/agents/support")
      expect(status).to eq(200)

      # No prefix, no app: the host owns everything else in its own namespace.
      status, = get(app, "/v1/agents/support")
      expect(status).to eq(404)
    end

    it "still gates on the token it was mounted with" do
      app = mounted(Insika::Server.rack_app(system, token: "tok"))
      status, = get(app, "/ai/v1/agents/support", auth: "WRONG")
      expect(status).to eq(401)
    end

    it "answers /v1/responses for ITS OWN graph — the turn lands in its store" do
      app = mounted(Insika::Server.rack_app(system, token: "tok"))
      stub_chat(system)

      env = Rack::MockRequest.env_for(
        "/ai/v1/responses", method: "POST",
        input: JSON.generate(model: "insika:support", user: "chat-1", stream: true, input: "oi")
      )
      env["HTTP_AUTHORIZATION"] = "Bearer tok"

      status, headers = Sync { app.call(env) }

      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("text/event-stream")
      expect(backend).to eq(system.runtime.graph.backend)
      expect(system.runtime.graph.session_store.find("chat-1")).not_to be_nil
      expect(other.runtime.graph.session_store.find("chat-1")).to be_nil
    end

    # Two mounted graphs are two apps. Nothing is shared between them but the
    # process — which is exactly what the embed contract promises.
    it "two graphs mount side by side without seeing each other's sessions" do
      app = Rack::URLMap.new(
        "/a" => Insika::Server.rack_app(system, token: "tok"),
        "/b" => Insika::Server.rack_app(other, token: "tok")
      )

      expect(get(app, "/a/v1/agents/support").first).to eq(200)
      expect(get(app, "/b/v1/agents/support").first).to eq(200)

      system.runtime.graph.session_store.create(id: "only-in-a", vars: {})
      expect(other.runtime.graph.session_store.find("only-in-a")).to be_nil
    end

    # The embed contract,: the PROCESS owns the reactor. A turn is a fiber,
    # so the routes that start one need a running reactor — Falcon supplies it,
    # Puma does not. Documented in docs/EMBEDDING.md as a limitation rather than
    # papered over: wrapping `call` in a Sync would make the request block until
    # the turn finished, which is the streaming contract broken to hide a 500.
    it "turn routes need the host's reactor; reads do not" do
      app = mounted(Insika::Server.rack_app(system, token: "tok"))
      stub_chat(system)

      status, = get(app, "/ai/v1/agents/support")
      expect(status).to eq(200) # no reactor, read-only: fine

      env = Rack::MockRequest.env_for(
        "/ai/v1/responses", method: "POST",
        input: JSON.generate(model: "insika:support", user: "chat-2", stream: true, input: "oi")
      )
      env["HTTP_AUTHORIZATION"] = "Bearer tok"
      status, _headers, body = app.call(env) # no reactor, starts a turn: 500

      expect(status).to eq(500)
      expect(JSON.parse(body.join).dig("error", "message")).to match(/async task/i)
    end

    def stub_chat(handle)
      chat = FakeChat.new
      chat.final_content = "hello"
      chat.script = proc { emit_chunk("hello") }
      handle.runtime.graph.executor.define_singleton_method(:create_chat) { |*_a, **_k| chat }
    end
  end
end
