# frozen_string_literal: true

require_relative "../../../lib/insika/testing/store_contract"

RSpec.describe Insika::Stores::Memory do
  subject(:store) { described_class.new }

  it_behaves_like "an Insika store"
end
