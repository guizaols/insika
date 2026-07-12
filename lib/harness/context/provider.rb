# frozen_string_literal: true

module Harness
  # Classe base de provider de contexto. Subclasses
  # concretas vivem em Harness::Context::Providers. A base é
  # deliberadamente mínima: `required?` mora no provider, não no wiring.
  class ContextProvider
    def id = self.class.name       # override para nome estável
    def required? = false          # true -> falha aborta o turno
    def enabled_for?(_profile) = true
    def call(_request) = []        # -> [ContextFragment]; pode fazer IO
  end

  # Input do contrato de provider.
  #   session:    SessionStore::Session | nil
  #   checkpoint: Checkpoint | nil (presente no ResumeTask — histórico vem dele)
  ContextRequest = Data.define(:session, :message, :profile, :tenant, :vars,
                               :checkpoint)
end
