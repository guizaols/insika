# frozen_string_literal: true

module Harness
  # Classe base de provider de contexto (RFC-0005 §2, doc 04 §2). Subclasses
  # concretas vivem em Harness::Context::Providers (task 15). A base é
  # deliberadamente mínima: `required?` mora no provider, não no wiring (L5).
  class ContextProvider
    def id = self.class.name       # override para nome estável
    def required? = false          # true -> falha aborta o turno (D4)
    def enabled_for?(_profile) = true
    def call(_request) = []        # -> [ContextFragment]; pode fazer IO
  end

  # Input do contrato de provider (doc 04 §2).
  #   session:    SessionStore::Session | nil (D2)
  #   checkpoint: Checkpoint | nil (presente no ResumeTask — histórico vem dele)
  ContextRequest = Data.define(:session, :message, :profile, :tenant, :vars,
                               :checkpoint)
end
