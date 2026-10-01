# frozen_string_literal: true

require_relative "../../../lib/insika/testing/store_contract"

# Runs only against a real server: INSIKA_TEST_DATABASE_URL (CI sets it).
RSpec.describe "Insika::Stores::Postgres", if: ENV["INSIKA_TEST_DATABASE_URL"] do
  let(:url) { ENV.fetch("INSIKA_TEST_DATABASE_URL") }
  subject(:store) { Insika::Stores::Postgres.new(url: url) }

  before do
    Insika::Stores::Postgres.new(url: url).tap { |s| s.send(:with_conn) { |c| c.exec("TRUNCATE insika_kv") } }.close
  end

  after { store.close }

  it_behaves_like "an Insika store"

  it "does not load pg until a Postgres store is built" do
    out = `#{RbConfig.ruby} -Ilib -e 'require "insika"; print defined?(PG) ? "loaded" : "lazy"'`
    expect(out).to eq("lazy")
  end
end
