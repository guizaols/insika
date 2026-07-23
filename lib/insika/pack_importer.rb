# frozen_string_literal: true

module Insika
  # Pack importer (Phase 6/D4/F6, task 7): reads a Pack and emits the ALREADY
  # existing authoring Commands — create_agent/update_agent + write_agent_file +
  # write_skill + write_data_tool — making an agent provisionable at runtime from
  # a standardized pack. It's the piece that achei-b2b's `GatewayClient`/
  # `ProvisionStore` triggers (via the provisioning API, task 8).
  #
  # GENERIC (NF1): nothing here mentions achei-b2b — the pack is the contract. Tool
  # names come from the PACK, so prompts<->tools stay consistent by construction
  # (NF2). It doesn't write to the store directly: it only dispatches Commands on
  # the bus (the same transport discipline) + READS the ProfileSource to decide
  # create vs update.
  #
  # IDEMPOTENT (upsert): re-importing the same pack reconciles — files/skills/
  # tools rewritten; the allowlists (prompt_files/skills/tools_allow) are
  # AUTHORITATIVE from the pack, so whatever left the pack leaves the agent
  # (isolation and no drift). An in-flight turn keeps the profile it captured.
  class PackImporter
    def initialize(bus:, profiles:)
      @bus = bus
      @profiles = profiles
    end

    # -> { agent_id:, created:, files: [names], skills: [names], tools: [names] }.
    # Validation/lookup errors from the Commands (missing id/model, etc.) propagate
    # (the transport maps them to 422/404).
    def import(pack)
      id = presence(pack.config[:id]) ||
           (raise Insika::ValidationError, "pack missing config.id")

      created = @profiles[id].nil?
      # create_agent rejects an already-existing id; update_agent requires it to
      # exist — the choice by presence makes the import an upsert.
      dispatch(created ? :create_agent : :update_agent, agent_attrs(pack, id))

      pack.files.each { |name, body| dispatch(:write_agent_file, { agent_id: id, file: name, content: body }) }
      pack.skills.each { |name, body| dispatch(:write_skill, { name: name, content: body }) }
      pack.tools.each { |defn| dispatch(:write_data_tool, defn) }

      { agent_id: id, created: created,
        files: pack.files.keys, skills: pack.skills.keys, tools: pack.tools.map { |t| tool_name(t) } }
    end

    # Removes the agent (delete_agent). Does NOT delete skills/tools/files: they
    # may be shared and the SkillStore/ToolStore are global — selective removal is
    # operator work. NotFoundError (missing agent) propagates -> 404.
    def delete(id)
      dispatch(:delete_agent, { id: id })
      { agent_id: id, deleted: true }
    end

    private

    # AgentProfile.build attrs: the pack manifest + the allowlists derived and
    # AUTHORITATIVE from the pack. This way the agent only sees the skills/tools of
    # its OWN pack (per-store isolation) and re-provisioning removes what left.
    #   - prompt_files = the pack's .md files (write_agent_file also registers;
    #     union is a no-op). Setting here makes the list authoritative (removes the ones that left).
    #   - skills = the pack's skills/ dirs (explicit allowlist; [] if none in the
    #     pack and config didn't declare any — never nil=all, which would leak
    #     skills from other stores).
    #   - tools_allow = (config.tools_allow) ∪ (the pack's tool names) — guarantees
    #     the agent can call its own data-tools (NF2).
    #   - tools_allow_groups = groups enabled by FLAG in the pack (see
    #     #enabled_groups) — the per-flag schema CUT (Phase 7, Stage E / D5): only
    #     the tools of the enabled groups (union with tools_allow) go to the model;
    #     those of disabled groups are cut BEFORE the turn (resolves the OpenClaw
    #     tool-call waste, where the flag only exists in Rails).
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

    # PER-FLAG CUT (Phase 7, Stage E / D5, STATIC pilot): derives the agent's
    # per-group allowlist from FLAGS declared in the pack config — DATA, never a
    # core convention (NF1). The engine doesn't know "groceries_v2"/"b2b": the pack
    # declares which GROUPS are enabled; the flag->group mapping is the
    # responsibility of provisioning/the pack, not the insika. Two forms (union):
    #   - `enabled_groups: ["default", "b2b"]`  — explicit list of ON groups.
    #   - `flags: { "b2b" => true, "natura" => false }` — the flag key IS the group
    #     name; only the truthy ones enter (the false ones CUT the group).
    # Neither declared -> nil (no per-group cut; old behavior).
    # Explicit `[]` (empty enabled_groups, or all flags false) -> no group.
    def enabled_groups(config)
      return nil unless config.key?(:enabled_groups) || config.key?(:flags)

      from_list = Array(config[:enabled_groups]).map(&:to_s)
      from_flags = flag_groups(config[:flags])
      (from_list | from_flags)
    end

    # { group => bool } -> [groups with a truthy value]. Accepts string|symbol keys.
    def flag_groups(flags)
      return [] unless flags.is_a?(Hash)

      flags.filter_map { |group, on| group.to_s if truthy?(on) }
    end

    def truthy?(val) = val == true || val.to_s == "true"

    def tool_name(defn) = (defn[:name] || defn["name"]).to_s

    def presence(str) = Insika::Coercion.presence(str)

    def dispatch(type, payload)
      @bus.dispatch(Insika::Command.build(type, payload, transport: :http))
    end
  end
end
