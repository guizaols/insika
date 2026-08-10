# frozen_string_literal: true

module Insika
  module Server
    module A2A
      # Remote A2A agents config. Parses "id=url,id2=url2".
      module Remotes
        Remote = Data.define(:id, :url, :description)

        # -> [Remote]. Malformed entries (no '=', empty id/url) are ignored
        # with a warn. env nil/"" -> [].
        def self.parse(env_string, descriptions: {})
          env_string.to_s.split(",").filter_map do |entry|
            id, url = entry.split("=", 2).map { |s| s.to_s.strip }
            if id.to_s.empty? || url.to_s.empty?
              warn "[a2a] malformed remote ignored: #{entry.inspect} (use id=url)"
              next
            end
            Remote.new(id: id, url: url, description: descriptions[id])
          end
        end
      end
    end
  end
end
