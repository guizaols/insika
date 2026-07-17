# frozen_string_literal: true

module Harness
  module Server
    module A2A
      # A2A AgentCard: discovery for the exposed agent. One agent
      # per deployment; HONEST capabilities (streaming/push false in this slice).
      module AgentCard
        def self.build(agent:, base_url:, skills: [], version: "0.1.0")
          {
            name: agent.id,
            description: agent.base_prompt.to_s[0, 280],
            url: "#{base_url}/a2a",
            version: version,
            protocolVersion: "0.2.5", # A2A wire — to confirm
            capabilities: { streaming: false, pushNotifications: false, stateTransitionHistory: false },
            defaultInputModes: ["text/plain"],
            defaultOutputModes: ["text/plain"],
            skills: Array(skills).map do |s|
              { id: s.name, name: s.name, description: s.description, tags: [] }
            end
          }
        end
      end
    end
  end
end
