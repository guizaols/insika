# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2"

# Gemfile mínimo para a suíte. A pinagem completa de D9
# (ruby_llm/falcon/rack) e o Gemfile.lock definitivo entram na task 26.
# async e sqlite3 entram aqui (task 4), quando são de fato usados:
# async é dependência do núcleo (semáforo de escrita do Stores::SQLite);
# sqlite3 é "apenas backend" (D9) — carregado lazy dentro do initialize,
# então fica no grupo de teste (produção declara a gem no app).
gem "async", "~> 2.0"
# rack: transporte do harness-server (task 24). Pinagem exata (~> 3.0) e
# Gemfile.lock definitivo são fechados na task 26 (D9).
gem "rack", "~> 3.0"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "sqlite3", "~> 2.0"
end
