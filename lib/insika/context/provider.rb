# frozen_string_literal: true

module Insika
  # Base class for a context provider. Concrete
  # subclasses live in Insika::Context::Providers. The base is
  # deliberately minimal: `required?` lives on the provider, not the wiring.
  class ContextProvider
    def id = self.class.name       # override for a stable name
    def required? = false          # true -> failure aborts the turn
    def enabled_for?(_profile) = true
    def call(_request) = []        # -> [ContextFragment]; may do IO
    # RFC-0030 C1: which cache layer the output belongs to.
    #   :identity -> changes only on deploy/config edit (the cacheable prefix);
    #   :volatile -> may change per turn (the Builder renders identity first).
    # :volatile is the conservative default — nothing gets pinned by accident.
    def layer = :volatile
  end

  # Input for the provider contract.
  #   session:      SessionStore::Session | nil
  #   checkpoint:   Checkpoint | nil (present on ResumeTask — history comes from it)
  #   memory_scope: the CUSTOMER-scoped memory cell (WS8): "[tenant:]customer"
  #                 when the request carries a customer, else nil (the providers
  #                 fall back to tenant || session). Kept separate from `tenant`
  #                 (the <request_context> merchant label) on purpose.
  ContextRequest = Data.define(:session, :message, :profile, :tenant, :vars,
                               :checkpoint, :memory_scope) do
    def initialize(session: nil, message: nil, profile: nil, tenant: nil, vars: {},
                   checkpoint: nil, memory_scope: nil)
      super
    end
  end
end
