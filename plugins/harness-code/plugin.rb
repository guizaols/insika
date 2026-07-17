# frozen_string_literal: true

require "ruby_llm"
require_relative "lib/harness_code/workspace"
require_relative "lib/harness_code/tools/read_file"
require_relative "lib/harness_code/tools/list_dir"
require_relative "lib/harness_code/tools/grep"
require_relative "lib/harness_code/tools/write_file"
require_relative "lib/harness_code/tools/edit_file"
require_relative "lib/harness_code/tools/bash"

# Autodiscoverable plugin (RFC-0003): the same shape as plugins/weather. The
# module responds to `.register(api)`; the Loader requires this file and calls
# it once at boot. Each tool is registered with a BLOCK factory (like the A2A
# remote tools in config/wiring.rb) so the Executor gets a fresh instance per
# turn — every instance shares one stateless, immutable Workspace built from
# HARNESS_CODE_ROOT (default: the process working directory).
#
# The manifest declares the six tool names and their side_effect flags; this
# file supplies the implementations. Whether write_file/edit_file/bash actually
# require human approval is decided by the AGENT PROFILE's `approvals_required`
# (see examples/harness-code/boot.rb) — the plugin only ships the tools.
module HarnessCodePlugin
  module_function

  def workspace
    root = ENV["HARNESS_CODE_ROOT"].to_s
    HarnessCode::Workspace.new(root.empty? ? Dir.pwd : root)
  end

  def register(api)
    ws = workspace
    api.register_tool("read_file")  { HarnessCode::Tools::ReadFile.new(workspace: ws) }
    api.register_tool("list_dir")   { HarnessCode::Tools::ListDir.new(workspace: ws) }
    api.register_tool("grep")       { HarnessCode::Tools::Grep.new(workspace: ws) }
    api.register_tool("write_file") { HarnessCode::Tools::WriteFile.new(workspace: ws) }
    api.register_tool("edit_file")  { HarnessCode::Tools::EditFile.new(workspace: ws) }
    api.register_tool("bash")       { HarnessCode::Tools::Bash.new(workspace: ws) }
  end
end
