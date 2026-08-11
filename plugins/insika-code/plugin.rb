# frozen_string_literal: true

require "ruby_llm"
require_relative "lib/insika_code/tools/read_file"
require_relative "lib/insika_code/tools/list_dir"
require_relative "lib/insika_code/tools/grep"
require_relative "lib/insika_code/tools/write_file"
require_relative "lib/insika_code/tools/edit_file"
require_relative "lib/insika_code/tools/bash"

# Autodiscoverable plugin: the same shape as plugins/weather. The
# module responds to `.register(api)`; the Loader requires this file and calls
# it once at boot. Each tool is registered with a BLOCK factory (like the A2A
# remote tools in config/wiring.rb) so the Executor gets a fresh instance per
# turn — every instance shares one stateless, immutable core Sandbox
# (`Insika::Sandbox::Env`).
#
# The Sandbox is assembled from declarative config: `HARNESS_CODE_SANDBOX`
# selects the provider (local [default] / docker) and `HARNESS_CODE_ROOT` the
# confinement root — the SAME shape stored on the agent profile's `sandbox`
# block (config-over-code). See examples/insika-code/boot.rb.
#
# The manifest declares the six tool names and their side_effect flags; this
# file supplies the implementations. Whether write_file/edit_file/bash actually
# require human approval is decided by the AGENT PROFILE's `approvals_required`.
module InsikaCodePlugin
  module_function

  # Declarative sandbox config, resolved from the environment. Empty/absent keys
  # are dropped so Insika::Sandbox.build applies its own defaults (local
  # provider, cwd root).
  def sandbox_config
    {
      "provider"   => ENV["HARNESS_CODE_SANDBOX"],
      "root"       => (ENV["HARNESS_CODE_ROOT"].to_s.empty? ? Dir.pwd : ENV["HARNESS_CODE_ROOT"]),
      "image"      => ENV["HARNESS_CODE_SANDBOX_IMAGE"],
      "network"    => ENV["HARNESS_CODE_SANDBOX_NETWORK"],
      "timeout"    => ENV["HARNESS_CODE_TOOL_TIMEOUT"],
      "max_output" => ENV["HARNESS_CODE_SANDBOX_MAX_OUTPUT"]
    }.reject { |_k, v| v.to_s.empty? }
  end

  def sandbox = Insika::Sandbox.build(sandbox_config)

  def register(api)
    sbx = sandbox
    api.register_tool("read_file")  { InsikaCode::Tools::ReadFile.new(sandbox: sbx) }
    api.register_tool("list_dir")   { InsikaCode::Tools::ListDir.new(sandbox: sbx) }
    api.register_tool("grep")       { InsikaCode::Tools::Grep.new(sandbox: sbx) }
    api.register_tool("write_file") { InsikaCode::Tools::WriteFile.new(sandbox: sbx) }
    api.register_tool("edit_file")  { InsikaCode::Tools::EditFile.new(sandbox: sbx) }
    api.register_tool("bash")       { InsikaCode::Tools::Bash.new(sandbox: sbx) }
  end
end
