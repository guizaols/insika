# frozen_string_literal: true

# RUN FOR REAL (no mock): a REAL, MULTI-TURN conversation with Bia (DeepSeek),
# serialized by the SessionActor. Each turn goes on the session's FIFO queue;
# turn 2 sees turn 1's transcript (session memory via the Session
# provider — the reconciled :vars seam). Streams the response, shows
# tools/skills/results. Inspect the same conversation in the Studio (/studio/chats).
#
# Operation (what unblocked multi-turn): arms executor.supervised = true
# (SessionActor + long-lived supervisor), and at the end DOES THE TEARDOWN
# (stop_session_actors + supervisor.stop) — otherwise the Sync block never returns
# (the long-lived fibers stay hung on dequeue).
#
# Usage: DEEPSEEK_API_KEY=... ruby scripts/run_real.rb

$stdout.sync = true
require_relative "../config/deployment"
require "async"

W = Deploy::Wiring
SESSION = "demo-bia"
W::SESSION_STORE.create(id: SESSION, vars: { "canal" => "web", "cliente" => "Ana" })

TURNS = ARGV.empty? ? ["Boa noite! Vocês estão abertos agora? Meu nome é Ana.",
                       "Perfeito. Quanto fica 2 pizzas margherita + 1 suco natural? Quero fechar o pedido."] : ARGV
TERMINAL = %w[completed failed cancelled].freeze

def stream_events(parent)
  sub = W::EVENT_STREAM.subscribe
  reader = parent.async do
    sub.each do |ev|
      case ev.type
      # The answer, published whole when its message ends. Everything the model said
      # on the way there is :intermediate — dimmed here so a real run SHOWS what the
      # customer does not get (this is the script the reasoning leak surfaced in).
      when :content         then puts("\n#{ev.data[:delta]}")
      when :intermediate    then print("\e[2m#{ev.data[:delta]}\e[0m")
      when :tool_call       then puts("\n  \e[36m→ #{ev.data[:name]}(#{ev.data[:arguments].inspect})\e[0m")
      when :tool_result     then puts("  \e[36m← #{ev.data[:name]}: #{ev.data[:result].to_s[0, 220]}\e[0m")
      when :skill_activated  then puts("\n  \e[35m↑ load_skill(#{ev.data[:name]})\e[0m")
      end
    end
  end
  [sub, reader]
end

@last_task = nil
Sync do |parent|
  W::EXECUTOR.supervised = true # arms serving mode: SessionActor serializes the session
  sub, reader = stream_events(parent)

  TURNS.each_with_index do |msg, i|
    puts "\n\e[1m═══ TURN #{i + 1} · Bia (DeepSeek #{Deploy::MODEL}) · session #{SESSION} ═══\e[0m"
    puts "\e[33mAna>\e[0m #{msg}\n\e[32mbia>\e[0m "

    # SESSION turn (session_id): enters the SessionActor's FIFO queue; turn 2
    # already sees turn 1 in the transcript (real memory, no mock).
    res = W::BUS.dispatch(Insika::Command.build(:send_message,
                                                 { agent: "bia", message: msg, session_id: SESSION },
                                                 transport: :cli))
    tid = res[:task_id]
    900.times do
      t = W::TASK_STORE.find(tid)
      break if t && TERMINAL.include?(t.status.to_s)

      parent.sleep(0.1)
    end
    @last_task = W::TASK_STORE.find(tid)
    puts "\n  \e[2m[status: #{@last_task&.status} · session turns: #{W::SESSION_STORE.find(SESSION).messages.size}]\e[0m"
  end

  # TEARDOWN (unblocks the Sync): shuts down the session's long-lived loops + the
  # supervisor. Without this the block hangs waiting on the idle fibers.
  sub.close
  reader.wait
  W::EXECUTOR.stop_session_actors
  W::EXECUTOR.instance_variable_get(:@supervisor)&.stop
end

msgs = W::SESSION_STORE.find(SESSION).messages
puts "\n\e[1m═══ SUMMARY ═══\e[0m"
puts "transcript persisted in the session (#{msgs.size} msgs): #{msgs.map { |m| m['role'] }.join(' → ')}"
