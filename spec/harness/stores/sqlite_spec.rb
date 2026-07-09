# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "sqlite3" # o spec pode requerer a gem; só o NÚCLEO tem a regra de lazy require
require_relative "../store_contract"

RSpec.describe Harness::Stores::SQLite do
  context "com banco :memory:" do
    subject(:store) { described_class.new(path: ":memory:") }

    after { store.close }

    it_behaves_like "a harness store"
  end

  context "com arquivo em tmpdir" do
    subject(:store) { described_class.new(path: db_path) }

    let(:tmpdir) { Dir.mktmpdir }
    let(:db_path) { File.join(tmpdir, "harness-test.db") }

    after do
      store.close
      FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
    end

    it_behaves_like "a harness store"

    # Os únicos testes específicos de backend permitidos (doc 01 §7).

    it "é durável: dados sobrevivem a close + reopen no mesmo arquivo" do
      store.set("s", "k", { "a" => 1 })
      store.transaction { store.set("s", "t", "commitado") }
      store.close

      reopened = described_class.new(path: db_path)
      expect(reopened.get("s", "k")).to eq({ "a" => 1 })
      expect(reopened.get("s", "t")).to eq("commitado")
      reopened.close
    end

    it "ativa o modo WAL no arquivo (PRAGMA journal_mode == 'wal')" do
      store.set("s", "k", 1) # garante que o arquivo existe

      inspect_db = SQLite3::Database.new(db_path)
      mode = inspect_db.get_first_value("PRAGMA journal_mode")
      inspect_db.close

      expect(mode).to eq("wal")
    end

    it "N fibers escrevendo + leitor concorrente sem SQLITE_BUSY" do
      require "async"

      Async do |task|
        writers = 8.times.map do |i|
          task.async do
            20.times { |n| store.transaction { store.set("scope-#{i}", "k#{n}", n) } }
          end
        end
        reader = task.async do
          50.times { store.list("scope-0") }
        end
        (writers + [reader]).each(&:wait)
      end

      expect(store.list("scope-3").length).to eq(20)
      expect(store.list("scope-0").length).to eq(20)
    end

    it "serializa duas transações concorrentes no mesmo scope (sem BEGIN IMMEDIATE falho)" do
      require "async"

      Async do |task|
        a = task.async { store.transaction { store.set("s", "a", 1) } }
        b = task.async { store.transaction { store.set("s", "b", 2) } }
        [a, b].each(&:wait)
      end

      expect(store.get("s", "a")).to eq(1)
      expect(store.get("s", "b")).to eq(2)
    end
  end

  describe "require lazy da gem sqlite3 (doc 01 §8)" do
    it "require \"harness\" não carrega a gem sqlite3 antes do primeiro new" do
      # Subprocess limpo: dentro da suíte a gem já foi requerida por outros
      # specs (ordem random), então testamos em um ruby isolado. bundler/setup
      # ativa o load path das gems (async é dependência do núcleo) mas NÃO faz
      # require de sqlite3 — só o initialize do backend o faz.
      script = 'require "bundler/setup"; require "harness"; ' \
               "exit(defined?(SQLite3) ? 1 : 0)"
      ok = system(RbConfig.ruby, "-Ilib", "-e", script,
                  out: File::NULL, err: File::NULL)
      expect(ok).to be(true)
    end
  end
end
