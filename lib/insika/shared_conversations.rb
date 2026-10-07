# frozen_string_literal: true
require 'json'
require 'securerandom'
require 'digest'

module Insika
  # Required HTTP persistence. The native backend owns the execution outbox;
  # the central service alone owns settled conversation history.
  class SharedConversations
    class Recovered < StandardError
      attr_reader :content, :output_parts, :attachments
      def initialize(content, output_parts: [], attachments: [])
        @content, @output_parts, @attachments = content, output_parts, attachments
        super('recorded shared result recovered')
      end
    end
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    SCOPE = 'shared_conversations'

    def initialize(url:, token:, store:)
      require 'uri'
      @url = URI(url)
      unless %w[http https].include?(@url.scheme) && @url.host && !@url.userinfo && !@url.query && !@url.fragment
        raise StoreError, 'invalid shared conversation URL'
      end
      raise StoreError, 'shared conversation token missing' if token.to_s.empty?
      raise StoreError, 'shared conversations require a durable native backend' unless Stores.durable?(store)
      @token, @store = token, store
    end

    def begin_turn(task:, profile:)
      data, payload = identity(task)
      acquire = !payload.fetch('shared_conversation').key?('generation')
      path = path_for(data)
      conversation = request('GET', path, missing: true)
      unless conversation
        raise StoreError, 'migrate existing chat history before shared execution' if data['history_required']
        request('PUT', path, data.slice('user_id','agent_id').merge('harness'=>'insika'))
        conversation = request('GET', path)
      end
      if conversation['user_id_pending'] == 1
        raise StoreError, 'shared conversation identity mismatch' unless conversation.values_at('tenant_id','agent_id') == data.values_at('tenant_id','agent_id')
        conversation = request('PUT', path, data.slice('user_id','agent_id').merge('harness'=>'insika'))
      end
      if data['history_required'] && conversation['last_sequence'].zero?
        raise StoreError, 'migrate existing chat history before shared execution'
      end
      key = key_for(data)
      old = @store.get(SCOPE,key)
      check_identity!(data, conversation, ownership: !acquire || !!old)
      if old
        raise StoreError, 'shared turn input differs' unless old['input_digest'] == input_digest(payload)
        raise StoreError, 'shared turn requires native reconciliation' unless old['messages']
        flush(data, old)
        raise Recovered.new(old['messages'].last['content'].filter_map { _1['text'] }.join("\n"), output_parts: old.fetch('output_parts', []), attachments: old.fetch('delivery_attachments', []))
      end
      raise StoreError, 'shared turn requires native reconciliation' if conversation['active_turn']
      data = data.merge('generation'=>conversation['generation'] + (conversation['assigned_harness'] == 'insika' ? 0 : 1)) if acquire
      history = history_at(path, conversation.fetch('last_sequence'))
      request('PUT', path+'/bindings/insika', {'generation'=>data['generation'], 'native_session_id'=>task.session_id || task.id,
        'synchronized_sequence'=>conversation['last_sequence']}) unless acquire
      input = canonical(task, {'role'=>'user','content'=>payload.fetch('user_text')}, id: data['message_id'])
      input['origin'] = payload['origin'] || 'customer'
      input['content'] = data['content'] if data['content']
      record = {'native_run_id'=>task.id, 'input_digest'=>input_digest(payload), 'sequence'=>conversation['last_sequence'] + 1, 'generation'=>data['generation']}
      # Write first: an ambiguous admission or registration must never authorize
      # another execution. Only a recorded result can be flushed automatically.
      @store.transaction do
        raise StoreError, 'shared turn requires native reconciliation' if @store.get(SCOPE,key)
        @store.set(SCOPE,key,record)
      end
      admission = {'id'=>data['turn_id'],'generation'=>data['generation'],
        'expected_sequence'=>conversation['last_sequence'],'message'=>input}
      admission.merge!('acquire'=>true, 'generation'=>conversation['generation'], 'native_session_id'=>task.session_id || task.id) if acquire
      turn = request('POST', path+'/turns', admission)
      raise StoreError, 'shared acquired generation differs' if acquire && turn['generation'] != data['generation']
      raise StoreError, 'shared turn requires native reconciliation' if turn['native_run_id'] || turn['state'] != 'running'
      request('PUT', path+"/turns/#{data['turn_id']}/native-run", {'generation'=>data['generation'],'native_run_id'=>task.id})
      project(history, path)
    end

    def resume_turn(task:, profile:, checkpoint:)
      data, = identity(task)
      path = path_for(data)
      conversation = request('GET',path)
      check_identity!(data,conversation)
      active = conversation['active_turn']
      record = @store.get(SCOPE,key_for(data))
      valid = task.status == :waiting && checkpoint.task_id == task.id && checkpoint.continuation &&
        active && active.values_at('id','native_run_id','state') == [data['turn_id'],task.id,'running'] &&
        record && record['native_run_id'] == task.id
      raise StoreError, 'shared turn requires native reconciliation' unless valid
      project(history_at(path,record['sequence'] - 1),path)
    end

    def complete(task:, messages:, pending_approval: false, output_parts: [], attachments: [])
      data, = identity(task)
      record = @store.get(SCOPE,key_for(data)) || raise(StoreError, 'shared admission missing')
      raise StoreError, 'shared native execution differs' unless record['native_run_id'] == task.id
      unless record['messages']
        output = messages.drop_while { _1['role'] == 'user' }
        raise StoreError, 'shared final answer missing' unless output.last && output.last['role'] == 'assistant'
        record['pending_approval'] = pending_approval
        record['messages'] = output.map do |message|
          full = record.fetch('tool_results', {})[message['tool_call_id']]
          if message['role'] == 'tool' && !full.nil?
            text = full.is_a?(String) ? full : JSON.generate(full)
            message = message.merge('content'=>text)
          end
          canonical(task, message)
        end
        record['output_parts'] = Array(output_parts)
        record['delivery_attachments'] = Array(attachments)
        record['uploads'] = Array(output_parts).map do |part|
          require 'base64'
          raise StoreError, 'invalid shared output media' unless %w[image audio].include?(part['type']) && part['base64'].is_a?(String)
          bytes = Base64.strict_decode64(part['base64'])
          raise StoreError, 'shared output exceeds 10 MiB' if bytes.bytesize > 10*1024*1024
          id = SecureRandom.uuid
          record['messages'].last['content'] << {'type'=>part['type'],'attachment_id'=>id}
          {'id'=>id,'base64'=>part['base64'],'mime_type'=>part.fetch('mime_type'),'sha256'=>Digest::SHA256.hexdigest(bytes)}
        end
        @store.set(SCOPE,key_for(data),record)
      end
      flush(data,record)
    end

    def input_attachments(task:)
      data, = identity(task)
      return [] unless data['content']
      project([{'role'=>'user', 'content'=>data['content']}],path_for(data)).first['attachments'].map { Media.hydrate_attachment(_1) }
    end

    def record_tool_result(task:, call_id:, result:)
      raise StoreError, 'shared tool correlation missing' if call_id.to_s.empty?
      data, = identity(task)
      @store.transaction do
        record = @store.get(SCOPE,key_for(data)) || raise(StoreError, 'shared admission missing')
        results = (record['tool_results'] ||= {})
        # The first capture precedes prompt-only evidence reshaping and clipping.
        results[call_id.to_s] ||= ToolTraceStore.mask(result.respond_to?(:content) ? result.content : result)
        @store.set(SCOPE,key_for(data),record)
      end
    end

    def identity(task)
      payload = task.command.fetch('payload')
      data = payload['shared_conversation']
      raise StoreError, 'explicit shared conversation identity required' unless data.is_a?(Hash)
      %w[tenant_id user_id agent_id conversation_id turn_id message_id].each do |name|
        raise StoreError, "invalid shared #{name}" unless data[name].is_a?(String) && UUID.match?(data[name])
      end
      if data.key?('generation')
        raise StoreError, 'invalid shared generation' unless data['generation'].is_a?(Integer) && data['generation'].positive?
      else
        record = @store.get(SCOPE,key_for(data))
        data = data.merge('generation'=>record.fetch('generation')) if record
      end
      raise StoreError, 'invalid shared history_required' unless [nil, true, false].include?(data['history_required'])
      raise StoreError, 'original user_text required' unless payload['user_text'].is_a?(String)
      content = data['content']
      if content
        valid = content.is_a?(Array) && content.all? do |part|
          part.is_a?(Hash) && (part['type'] == 'text' ? part['text'].is_a?(String) :
            %w[image audio document].include?(part['type']) && part['attachment_id'].is_a?(String) && UUID.match?(part['attachment_id']))
        end
        raise StoreError, 'invalid shared content' unless valid
        raise StoreError, 'shared content differs from original speech' unless content.filter_map { _1['text'] }.join("\n") == payload['user_text']
      end
      if Media.parts(payload['parts']).any? { !_1.text? } && !Array(content).any? { _1['type'] != 'text' }
        raise StoreError, 'upload media to central storage before admission'
      end
      tenant = task.command.fetch('meta')['tenant']
      raise StoreError, 'shared tenant identity differs' unless tenant.to_s == data['tenant_id']
      [data,payload]
    end

    def memory_context(task:, profile:)
      data, payload = identity(task)
      result = {}
      if profile.memory
        refs = request('GET', "/v1/memories/user/#{data['user_id']}?limit=50")['memories']
        result['facts'] = refs.filter_map { memory_get(task:task,id:_1['id']) }
        path = "/v1/memories/conversation/#{data['conversation_id']}"
        request('GET',path+'?limit=50')['memories'].each do |ref|
          record = request('GET',path+'/'+URI.encode_www_form_component(ref['id']),missing:true)
          result['facts'] << record.merge('id'=>"conversation.#{record['id']}") if record
        end
      end
      if Coercion.truthy?(profile.knowledge&.dig('retrieve'))
        query = URI.encode_www_form_component(payload['user_text'][0, 200])
        result['knowledge'] = request('GET', "/v1/memories/agent/#{data['agent_id']}?limit=5&query=#{query}")['memories']
      end
      result
    end

    def memory_get(task:, id:, kind: 'fact', include_proposed: false)
      data, = identity(task)
      scope, owner = kind == 'knowledge' ? ['agent',data['agent_id']] : ['user',data['user_id']]
      path = "/v1/memories/#{scope}/#{owner}/#{URI.encode_www_form_component(id)}"
      path += '?include_proposed=true' if include_proposed
      request('GET', path, missing:true)
    end

    def propose_memory(task:, id:, value:, kind: 'fact')
      data, = identity(task)
      scope, owner = kind == 'knowledge' ? ['agent',data['agent_id']] : ['user',data['user_id']]
      current = memory_get(task:task,id:id,kind:kind,include_proposed:true)
      recorded = @store.get(SCOPE,key_for(data))
      source_ids = [data['message_id']] + Array(recorded && recorded['messages']).map { _1['id'] }
      clean = value.is_a?(String) ? Safety::Detectors.redact(value).first : ToolTraceStore.mask(value)
      request('PUT', "/v1/memories/#{scope}/#{owner}/#{URI.encode_www_form_component(id)}",
        {'value'=>clean,'kind'=>kind,'origin'=>'insika','status'=>'proposed','expected_revision'=>current ? current['revision'] : 0,
         'sources'=>source_ids.uniq.map { {'conversation_id'=>data['conversation_id'],'message_id'=>_1} }})
    end

    private

    def check_identity!(data, conversation, ownership: true)
      unless conversation.values_at('tenant_id','user_id','agent_id') == data.values_at('tenant_id','user_id','agent_id') &&
             (!ownership || conversation.values_at('assigned_harness','generation') == ['insika',data['generation']])
        raise StoreError, 'shared conversation identity or generation mismatch'
      end
    end

    def key_for(data) = data.values_at('tenant_id','conversation_id','turn_id').join(':')
    def path_for(data) = "/v1/conversations/#{data['conversation_id']}"
    def input_digest(payload) = Digest::SHA256.hexdigest(JSON.generate(payload.slice('shared_conversation','user_text','origin')))

    def canonical(task, message, id: SecureRandom.uuid)
      result = {'schema_version'=>1,'id'=>id,'role'=>message.fetch('role'),
        'content'=>[{'type'=>'text','text'=>message.fetch('content').to_s}],
        'source'=>{'harness'=>'insika','session_id'=>task.session_id || task.id}}
      result.merge!(ToolTraceStore.mask(message.slice('tool_calls','tool_call_id','origin','outcome')))
      result
    end

    def flush(data, record)
      require 'base64'
      record.fetch('uploads',[]).each do |upload|
        request('PUT',path_for(data)+"/attachments/#{upload['id']}",Base64.strict_decode64(upload['base64']),
          headers: {'Content-Type'=>upload['mime_type'],'X-Filename'=>upload['id'],
            'X-Content-SHA256'=>upload['sha256'],'X-Conversation-Generation'=>data['generation'].to_s})
      end
      path = path_for(data)+"/turns/#{data['turn_id']}"
      prefix = record.fetch('messages')[0...-1]
      prefix.each_with_index do |message, index|
        request('POST', path+'/messages', {'generation'=>data['generation'],'expected_sequence'=>record['sequence']+index,'messages'=>[message]})
      end
      request('POST', path+'/complete', {'generation'=>data['generation'],
        'expected_sequence'=>record['sequence']+prefix.length,'message'=>record['messages'].last,'pending_approval'=>record.fetch('pending_approval',false)})
    end

    def history_at(path, sequence)
      messages, cursor = [], 0
      while cursor < sequence
        page = request('GET', path+"/messages?after_sequence=#{cursor}&through_sequence=#{sequence}&limit=10")
        raise StoreError, 'shared history cursor did not advance' unless page['next_sequence'].is_a?(Integer) && page['next_sequence'] > cursor
        messages.concat(page.fetch('messages'))
        cursor = page['next_sequence']
      end
      messages
    end

    def project(messages, path)
      messages.map do |message|
        text, attachments = [], []
        message.fetch('content').each do |part|
          if part['type'] == 'text'
            text << part.fetch('text')
          else
            id = part.fetch('attachment_id')
            raise StoreError, 'invalid shared attachment ID' unless UUID.match?(id)
            bytes, headers = request('GET', path+"/attachments/#{id}", raw: true)
            raise StoreError, 'shared attachment hash mismatch' unless Digest::SHA256.hexdigest(bytes) == headers['x-content-sha256']
            require 'base64'
            extension = {'image/png'=>'png','image/jpeg'=>'jpg','image/webp'=>'webp','image/gif'=>'gif',
              'application/pdf'=>'pdf','audio/mpeg'=>'mp3','audio/wav'=>'wav','audio/ogg'=>'ogg','audio/webm'=>'webm','text/plain'=>'txt'}.fetch(headers['content-type'],'bin')
            attachments << {'base64'=>Base64.strict_encode64(bytes),'filename'=>"#{id}.#{extension}"}
          end
        end
        projected = message.slice('role','origin').merge('content'=>text.join("\n"),'attachments'=>attachments)
        # RubyLLM checks answered call IDs across its entire chat, not per turn.
        call_id = ->(id) { "history_#{Digest::SHA256.hexdigest("#{message.fetch('turn_id')}:#{id}")[0, 48]}" }
        projected['tool_calls'] = message['tool_calls'].map { _1.merge('id'=>call_id.call(_1['id'])) } if message['tool_calls']
        projected['tool_call_id'] = call_id.call(message['tool_call_id']) if message['tool_call_id']
        projected
      end
    end

    def request(method, path, data = nil, raw: false, headers: {}, missing: false)
      require 'net/http'
      uri = @url.dup
      uri.path = @url.path.delete_suffix('/') + path.split('?',2).first
      uri.query = path.split('?',2)[1]
      body = data.is_a?(String) ? data : data && JSON.generate(data)
      raise StoreError, 'shared request exceeds 1 MiB' if body && !data.is_a?(String) && body.bytesize > 1_048_576
      request = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri,
        {'Authorization'=>"Bearer #{@token}", 'Content-Type'=>'application/json'}.merge(headers))
      request.body = body if body
      Net::HTTP.start(uri.host, uri.port, nil, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 10, write_timeout: 10) do |http|
        http.max_retries = 0
        http.request(request) do |response|
          return nil if missing && response.code == '404'
          raise StoreError, "shared conversation HTTP #{response.code}" unless response.code == '200'
          bytes = +''.b
          response.read_body do |chunk|
            bytes << chunk
            raise StoreError, 'shared response too large' if bytes.bytesize > (raw ? 10 : 16)*1024*1024
          end
          return raw ? [bytes,response.to_hash.transform_values(&:first)] : JSON.parse(bytes)
        end
      end
    rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, SocketError => error
      raise StoreError, "shared conversation transport failed (#{error.class})"
    end
  end
end
