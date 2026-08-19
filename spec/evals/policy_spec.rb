# frozen_string_literal: true

require "spec_helper"

# `policy` — how much a store wants its agent to ask before acting.
# Two halves: a deterministic check that needs no model (here) and an instruction the
# judge is told (judge_spec). Pure over (Golden, [TurnResult]) — no server, no tokens.
#
# The case that motivated it is REAL and both sides of it are in this file verbatim.
# A pilot store's own AGENTS.md rule:
#
#   "UMA PERGUNTA POR VEZ. Máximo 1 pergunta principal por mensagem = 1 ponto de
#    interrogação no fim, sem sub-perguntas aninhadas."
#
# Insika broke it on the first turn of the spike; the incumbent, on the equivalent
# move, asks exactly one. Neither needs a judge to tell apart.
RSpec.describe "Insika::Evals policy checks" do
  INSIKA_REPLY = "Pra eu te ajudar a achar o vestido perfeito: é pra você ou tá pensando em " \
                 "presentear alguém? E qual seu tamanho? Os vestidos vão de PP a GG."
  INCUMBENT_REPLY = "Separo umas opções na mesma vibe folk pra você ✨ Qual número você usa?"

  def golden(expect, turns: [{ "user" => "queria um vestido pra um casamento no fim da tarde" }])
    Insika::Evals::GoldenLoader.build({ "id" => "c", "agent" => "loja-moda",
                                        "turns" => turns, "expect" => expect })
  end

  def turn(text, tools: [])
    Insika::Evals::TurnResult.new(output_text: text, tool_calls: tools.map { |t| { "name" => t } }, error: nil)
  end

  def evaluate(expect, turns)
    Insika::Evals::Assertions.evaluate(golden(expect), turns.last, turns: turns)
  end

  describe "ask_once — the rule the spike caught being broken" do
    it "FAILS the reply Insika actually produced" do
      r = evaluate({ "policy" => "ask_once" }, [turn(INSIKA_REPLY)])

      expect(r.pass?).to be(false)
      expect(r.failures.first.name).to eq("policy:ask_once")
      expect(r.failures.first.detail).to include("2 questions")
    end

    it "PASSES the incumbent's reply on the equivalent move" do
      r = evaluate({ "policy" => "ask_once" }, [turn(INCUMBENT_REPLY)])

      expect(r.pass?).to be(true)
    end

    it "checks EVERY reply, not just the last — the violation was on turn 1" do
      r = evaluate({ "policy" => "ask_once" }, [turn(INSIKA_REPLY), turn("Fechado, vou separar.")])

      expect(r.pass?).to be(false)
      expect(r.failures.first.detail).to include("turn 1")
    end

    it "a run of question marks is ONE question, not three" do
      r = evaluate({ "policy" => "ask_once" }, [turn("já pensou no tamanho???")])

      expect(r.pass?).to be(true)
    end

    it "a tracking link's query string is not the agent asking something" do
      r = evaluate({ "policy" => "ask_once" },
                   [turn("Segue o rastreio: https://rastreio.com/t?code=AB1&x=2 — chegou?")])

      expect(r.pass?).to be(true)
    end
  end

  describe "investigate_first — establish the objective before acting" do
    it "passes when the agent asks and calls nothing" do
      r = evaluate({ "policy" => "investigate_first" }, [turn("Qual é seu objetivo: energia, treino ou sono?")])

      expect(r.pass?).to be(true)
    end

    it "fails when it searches on the first vague message" do
      r = evaluate({ "policy" => "investigate_first" },
                   [turn("Achei estes:", tools: %w[search_products])])

      expect(r.pass?).to be(false)
      expect(r.failures.first.detail).to include("search_products")
    end

    it "fails when it neither asks nor acts — a dead end is not investigation" do
      r = evaluate({ "policy" => "investigate_first" }, [turn("Temos várias opções de vitaminas.")])

      expect(r.pass?).to be(false)
    end
  end

  describe "act_fast — act on the first plausible reading" do
    it "passes when the agent calls a tool" do
      r = evaluate({ "policy" => "act_fast" }, [turn("Achei três:", tools: %w[search_products])])

      expect(r.pass?).to be(true)
    end

    it "fails when it asks something it could have answered by searching" do
      r = evaluate({ "policy" => "act_fast" }, [turn("Você prefere qual sabor?")])

      expect(r.pass?).to be(false)
      expect(r.failures.first.detail).to include("asked instead of acting")
    end
  end

  describe "no policy declared" do
    it "adds no check at all — most stores have no opinion, and a default would invent one" do
      r = evaluate({ "must_not" => ["pii_leak"] }, [turn(INSIKA_REPLY)])

      expect(r.checks.map(&:name)).to eq(["must_not:pii_leak"])
      expect(r.pass?).to be(true)
    end
  end

  # Three lists have to agree: what the loader accepts, what the checker dispatches on,
  # and what the judge is told. Two of them drifting apart is silent — a case would keep
  # passing while its rule stopped being checked, or the judge would grade a rule nobody
  # stated.
  describe "the policy catalog" do
    it "every known policy has a deterministic rule" do
      Insika::Evals::Assertions::POLICIES.each_key do |name|
        expect { evaluate({ "policy" => name }, [turn("oi?")]) }.not_to raise_error
      end
    end

    it "every known policy has a judge instruction" do
      expect(Insika::Evals::Judge::POLICY_INSTRUCTIONS.keys)
        .to match_array(Insika::Evals::Assertions::POLICIES.keys)
    end
  end

  describe "a typo'd policy" do
    it "is refused at load time instead of quietly checking nothing" do
      expect { golden({ "policy" => "ask_onc" }) }
        .to raise_error(Insika::Evals::GoldenLoader::InvalidGolden, /unknown policy "ask_onc".*ask_once/m)
    end
  end
end
