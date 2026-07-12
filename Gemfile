# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2"

# Pinagem D9 (00-overview): o núcleo (lib/) não requer ruby_llm em load-time
# (require lazy no Executor/LoadSkill — spec/harness/load_guard_spec cobre),
# mas a gem passa a estar SEMPRE no bundle. Os comentários "apenas em
# harness-server" documentam a fronteira da futura separação de gems.
gem "ruby_llm", ">= 1.15"  # before_tool_call/after_tool_result exigem 1.15+
gem "async", "~> 2.0"      # núcleo (reactor, semáforo de escrita do SQLite)
gem "falcon", "~> 0.55"    # servidor async (apenas em harness-server)
gem "sqlite3", "~> 2.0"    # apenas backend SQLite
gem "rack", "~> 3.0"       # transporte (apenas em harness-server)

# Studio (Fase 4 — UI de gestão). FRAMEWORK NA BORDA: usado SÓ pelo app `studio/`
# (roteador em árvore fino sob Falcon, sem ActiveRecord); `lib/harness` e `server/`
# NÃO dependem de Roda. tilt+erubi rendem os templates ERB com escape automático.
gem "roda", "~> 3.85"      # apenas em harness-studio
gem "tilt", "~> 2.8"       # render de templates (studio)
gem "erubi", "~> 1.13"     # ERB com escape automático (XSS-safe) para o studio

group :development, :test do
  gem "rspec"
end
