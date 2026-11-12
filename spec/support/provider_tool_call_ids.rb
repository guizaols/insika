# frozen_string_literal: true

# RubyLLM 2.2 gives each tool call of a provider response its own UUID (the
# provider's id stays in ToolCall#provider_call_id). Specs that script provider
# replies with ids like "write-1" tag themselves `provider_tool_call_ids: true`
# to keep those ids, so they assert Insika's behavior and not the gem's id format.
RSpec.configure do |config|
  config.before(:each, :provider_tool_call_ids) do
    allow_any_instance_of(RubyLLM::Chat::ToolCallIds).to receive(:id_for) { |_ids, id| id }
  end
end
