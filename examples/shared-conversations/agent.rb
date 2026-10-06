# frozen_string_literal: true
require_relative '../../lib/insika'

# Set INSIKA_DB, INSIKA_CONVERSATIONS_URL and INSIKA_CONVERSATIONS_TOKEN.
# Enroll the synthetic identity first; send the explicit metadata documented in
# docs/SHARED-CONVERSATIONS.md through the tenant-authenticated Responses route.
Insika.agent('shared-test') do
  model 'deepseek-v4-flash'
  provider :deepseek
  instructions 'Answer briefly. Use the prior conversation when relevant.'
  shared_conversations true
end.serve
