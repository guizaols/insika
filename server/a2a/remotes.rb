# frozen_string_literal: true

module Harness
  module Server
    module A2A
      # Config dos agentes A2A remotos (P3B, D6). Parse de "id=url,id2=url2".
      module Remotes
        Remote = Data.define(:id, :url, :description)

        # -> [Remote]. Entradas malformadas (sem '=', id/url vazios) são ignoradas
        # com warn. env nil/"" -> [].
        def self.parse(env_string, descriptions: {})
          env_string.to_s.split(",").filter_map do |entry|
            id, url = entry.split("=", 2).map { |s| s.to_s.strip }
            if id.to_s.empty? || url.to_s.empty?
              warn "[a2a] remoto malformado ignorado: #{entry.inspect} (use id=url)"
              next
            end
            Remote.new(id: id, url: url, description: descriptions[id])
          end
        end
      end
    end
  end
end
