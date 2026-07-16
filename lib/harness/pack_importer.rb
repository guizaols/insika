# frozen_string_literal: true

module Harness
  # Importador de pack (Fase 6/D4/F6, task 7): lê um Pack e emite os Commands de
  # autoria JÁ existentes — create_agent/update_agent + write_agent_file +
  # write_skill + write_data_tool — tornando um agente provisionável em runtime a
  # partir de um pack padronizado. É a peça que o `GatewayClient`/`ProvisionStore`
  # do consumer-app aciona (via a API de provisionamento, task 8).
  #
  # GENÉRICO (NF1): nada aqui cita consumer-app — o pack é o contrato. Os nomes de
  # tool vêm do PACK, então prompts<->tools ficam consistentes por construção
  # (NF2). Não escreve em store direto: só despacha Commands no bus (mesma
  # disciplina do transporte) + LÊ o ProfileSource p/ decidir create vs update.
  #
  # IDEMPOTENTE (upsert): re-importar o mesmo pack reconcilia — arquivos/skills/
  # tools reescritos; as allowlists (prompt_files/skills/tools_allow) são
  # AUTORITATIVAS a partir do pack, então o que saiu do pack sai do agente
  # (isolamento e sem drift). Um turno em andamento mantém o profile que capturou.
  class PackImporter
    def initialize(bus:, profiles:)
      @bus = bus
      @profiles = profiles
    end

    # -> { agent_id:, created:, files: [names], skills: [names], tools: [names] }.
    # Erros de validação/lookup dos Commands (id/model ausente, etc.) propagam
    # (o transporte os mapeia a 422/404).
    def import(pack)
      id = presence(pack.config[:id]) ||
           (raise Harness::ValidationError, "pack sem config.id")

      created = @profiles[id].nil?
      # create_agent recusa id já existente; update_agent exige que exista — a
      # escolha por presença torna o import um upsert.
      dispatch(created ? :create_agent : :update_agent, agent_attrs(pack, id))

      pack.files.each { |name, body| dispatch(:write_agent_file, { agent_id: id, file: name, content: body }) }
      pack.skills.each { |name, body| dispatch(:write_skill, { name: name, content: body }) }
      pack.tools.each { |defn| dispatch(:write_data_tool, defn) }

      { agent_id: id, created: created,
        files: pack.files.keys, skills: pack.skills.keys, tools: pack.tools.map { |t| tool_name(t) } }
    end

    # Remove o agente (delete_agent). NÃO apaga skills/tools/arquivos: podem ser
    # compartilhados e o SkillStore/ToolStore são globais — remoção seletiva é
    # trabalho de operador. NotFoundError (agente ausente) propaga -> 404.
    def delete(id)
      dispatch(:delete_agent, { id: id })
      { agent_id: id, deleted: true }
    end

    private

    # attrs do AgentProfile.build: o manifesto do pack + as allowlists derivadas
    # e AUTORITATIVAS do pack. Assim o agente só enxerga as skills/tools do
    # PRÓPRIO pack (isolamento por loja) e re-provisionar remove o que saiu.
    #   - prompt_files = os .md do pack (write_agent_file também registra; união
    #     no-op). Setar aqui torna a lista autoritativa (remove os que saíram).
    #   - skills = os dirs de skills/ do pack (allowlist explícita; [] se nenhum
    #     no pack e config não declarou — nunca nil=todas, que vazaria skills de
    #     outras lojas).
    #   - tools_allow = (config.tools_allow) ∪ (nomes das tools do pack) — garante
    #     que o agente pode chamar as próprias data-tools (NF2).
    #   - tools_allow_groups = grupos habilitados por FLAG no pack (ver
    #     #enabled_groups) — o CORTE de schema por flag (Fase 7, Etapa E / D5): só
    #     as tools dos grupos habilitados (união com tools_allow) vão pro modelo;
    #     as dos grupos desabilitados são cortadas ANTES do turno (resolve o
    #     desperdício de tool-call do OpenClaw, onde a flag só existe no Rails).
    def agent_attrs(pack, id)
      attrs = pack.config.dup
      attrs[:id] = id
      attrs[:prompt_files] = pack.files.keys unless pack.files.empty?
      attrs[:skills] = pack.skills.keys if pack.skills.any? || pack.config.key?(:skills)

      pack_tools = pack.tools.map { |t| tool_name(t) }
      allow = Array(pack.config[:tools_allow]).map(&:to_s) | pack_tools
      attrs[:tools_allow] = allow unless allow.empty? && !pack.config.key?(:tools_allow)

      groups = enabled_groups(pack.config)
      attrs[:tools_allow_groups] = groups unless groups.nil?
      attrs
    end

    # CORTE POR FLAG (Fase 7, Etapa E / D5, piloto ESTÁTICO): deriva a allowlist por
    # grupo do agente a partir de FLAGS declaradas no pack config — DADO, nunca
    # convenção do core (NF1). O motor não conhece "groceries_v2"/"b2b": o pack
    # declara quais GRUPOS estão habilitados; o mapeamento flag->grupo é
    # responsabilidade do provisionamento/pack, não do harness. Duas formas (união):
    #   - `enabled_groups: ["default", "b2b"]`  — lista explícita de grupos ON.
    #   - `flags: { "b2b" => true, "demo" => false }` — a chave da flag É o nome
    #     do grupo; só as truthy entram (as false CORTAM o grupo).
    # Nenhuma das duas declarada -> nil (sem corte por grupo; comportamento antigo).
    # `[]` explícito (enabled_groups vazio, ou flags todas false) -> nenhum grupo.
    def enabled_groups(config)
      return nil unless config.key?(:enabled_groups) || config.key?(:flags)

      from_list = Array(config[:enabled_groups]).map(&:to_s)
      from_flags = flag_groups(config[:flags])
      (from_list | from_flags)
    end

    # { grupo => bool } -> [grupos com valor truthy]. Aceita chaves string|symbol.
    def flag_groups(flags)
      return [] unless flags.is_a?(Hash)

      flags.filter_map { |group, on| group.to_s if truthy?(on) }
    end

    def truthy?(val) = val == true || val.to_s == "true"

    def tool_name(defn) = (defn[:name] || defn["name"]).to_s

    def presence(str) = Harness::Coercion.presence(str)

    def dispatch(type, payload)
      @bus.dispatch(Harness::Command.build(type, payload, transport: :http))
    end
  end
end
