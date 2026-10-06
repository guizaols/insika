# frozen_string_literal: true
require 'spec_helper'
require 'tmpdir'
require 'socket'
require 'net/http'
require 'timeout'

RSpec.describe 'Insika with the real central HTTP service' do
  around do |example|
    source = ENV['SHARED_CONVERSATIONS_SOURCE']
    skip 'set SHARED_CONVERSATIONS_SOURCE to run the local service proof' unless source
    Dir.mktmpdir('insika-shared-http-') do |dir|
      @dir, @source = dir, source
      socket = TCPServer.new('127.0.0.1', 0)
      @port = socket.addr[1]
      socket.close
      @ids = %w[tenant_id user_id agent_id conversation_id].to_h { [_1, SecureRandom.uuid] }
      @credentials = %w[insika openclaw operator].map do |harness|
        @ids.slice('tenant_id').merge('token'=>harness,'user_ids'=>[@ids['user_id']], 'agent_ids'=>[@ids['agent_id']],
          'harness'=>harness, 'operator'=>harness == 'operator')
      end
      @backend = Insika::Stores::SQLite.new(path: File.join(dir,'native.sqlite3'))
      boot_service
      example.run
    ensure
      stop_service
      @backend&.close
    end
  end

  def boot_service
    env = {'BUNDLE_GEMFILE'=>File.join(@source,'Gemfile'), 'CONVERSATIONS_DB'=>File.join(@dir,'central.sqlite3'),
      'CONVERSATIONS_CREDENTIALS'=>JSON.generate(@credentials),'CONVERSATIONS_BIND'=>"http://127.0.0.1:#{@port}"}
    @pid = Bundler.with_unbundled_env do
      Process.spawn(env, RbConfig.ruby, File.join(@source,'bin/server'), chdir: @source,
        out: File.join(@dir,'server.log'), err: [:child,:out], pgroup: true)
    end
    100.times do
      if Process.waitpid(@pid,Process::WNOHANG)
        status = $?.inspect
        @pid = nil
        raise "central child exited #{status}: #{File.read(File.join(@dir,'server.log'))}"
      end
      begin
        return if Net::HTTP.new('127.0.0.1',@port,nil).get('/ready').code == '200'
      rescue SystemCallError, IOError
        sleep 0.05
      end
    end
    raise "central service unavailable: #{File.read(File.join(@dir,'server.log'))}"
  end
  def stop_service
    return unless @pid
    return if Process.waitpid(@pid,Process::WNOHANG)
    Process.kill('TERM',-@pid)
    Timeout.timeout(5) { Process.wait(@pid) }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @pid = nil
  end
  def bridge(token = 'insika')
    Insika::SharedConversations.new(url: "http://127.0.0.1:#{@port}",token: token,store: @backend)
  end
  def api(method, suffix, body = nil, token: 'insika')
    bridge(token).send(:request, method, "/v1/conversations/#{@ids['conversation_id']}#{suffix}",body)
  end
  def canonical(role, text, **extra)
    {'schema_version'=>1,'id'=>SecureRandom.uuid,'role'=>role,'content'=>[{'type'=>'text','text'=>text}],
      'source'=>{'harness'=>'openclaw','session_id'=>'synthetic-openclaw'}}.merge(extra.transform_keys(&:to_s))
  end
  def run_task(runtime, task, profile)
    Sync do
      runtime.spawn(task,profile:profile)
      runtime.instance_variable_get(:@running)[task.id]&.wait
    end
  end

  it 'hydrates a foreign history, records real tool results, and recovers a lost ack across restarts without rerunning tools' do
    api('PUT','',@ids.slice('user_id','agent_id').merge('harness'=>'openclaw'),token:'openclaw')
    seed_id = SecureRandom.uuid
    require 'base64'
    attachment_id = SecureRandom.uuid
    image_bytes = Base64.strict_decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=')
    bridge('openclaw').send(:request,'PUT',"/v1/conversations/#{@ids['conversation_id']}/attachments/#{attachment_id}",image_bytes,
      headers:{'Content-Type'=>'image/png','X-Filename'=>'synthetic.png','X-Content-SHA256'=>Digest::SHA256.hexdigest(image_bytes),'X-Conversation-Generation'=>'1'})
    seed = canonical('user','Prefiro azul 👋')
    seed['content'] << {'type'=>'image','attachment_id'=>attachment_id}
    api('POST','/turns',{'id'=>seed_id,'generation'=>1,'expected_sequence'=>0,'message'=>seed},token:'openclaw')
    api('PUT',"/turns/#{seed_id}/native-run",{'generation'=>1,'native_run_id'=>'synthetic-openclaw'},token:'openclaw')
    api('POST',"/turns/#{seed_id}/complete",{'generation'=>1,'expected_sequence'=>1,'message'=>canonical('assistant','Preference recorded')},token:'openclaw')
    api('PUT','/binding',{'harness'=>'insika','expected_generation'=>1},token:'operator')

    sessions = Insika::SessionStore.new(store:@backend)
    tasks = Insika::TaskStore.new(store:@backend)
    checkpoints = Insika::CheckpointStore.new(store:@backend)
    events = SpyEventStream.new
    sessions.create(id:'synthetic-insika')
    sessions.append_messages('synthetic-insika',[{'role'=>'user','content'=>'stale local history'}])
    profile = Insika::AgentProfile.build(id:'synthetic',model:'deepseek-v4-flash',provider:'deepseek',shared_conversations:true)
    requests, effects = [], []
    tool = Class.new(RubyLLM::Tool) do
      define_method(:name) { 'lookup' }
      define_method(:execute) { effects << 'read'; {'value'=>'x'*10_000,'api_key'=>'private'} }
    end.new
    call = RubyLLM::Message.new(role: :assistant,content:'',tool_calls:{'lookup-1'=>RubyLLM::ToolCall.new(id:'lookup-1',name:'lookup',arguments:{})})
    responses = [call, RubyLLM::Message.new(role: :assistant,content:'Blue is available')]
    allow_any_instance_of(RubyLLM::Providers::DeepSeek).to receive(:complete) do |_provider,messages,**options,&stream|
      requests << messages.map(&:to_h)
      answer = responses.shift || raise('unexpected paid work')
      stream&.call(RubyLLM::Chunk.new(role: :assistant,content:answer.content)) unless answer.content.empty?
      answer
    end
    central = bridge
    failed_ack = false
    allow(central).to receive(:request).and_wrap_original do |original,method,path,*args,**options|
      result = original.call(method,path,*args,**options)
      if path.end_with?('/complete') && !failed_ack
        failed_ack = true
        raise Insika::StoreError, 'synthetic dropped acknowledgment'
      end
      result
    end
    build_runtime = lambda do |client|
      Insika::Executor.new(context_builder:Insika::ContextBuilder.new(providers:[Insika::Context::Providers::Session.new(session_store:sessions)],event_stream:events),
        policy_engine:NullPolicyEngine.new(allowed_tools:[tool]),middleware:PassthroughMiddleware.new,hooks:NullHooks.new,
        tool_registry:FakeToolRegistry.new,skill_catalog:Insika::SkillCatalog.new([]),profiles:{'synthetic'=>profile},
        session_store:sessions,task_store:tasks,checkpoint_store:checkpoints,event_stream:events,shared_conversations:client,
        llm:RubyLLM.context { |config| config.deepseek_api_key = 'synthetic' })
    end
    identity = @ids.merge('turn_id'=>SecureRandom.uuid,'message_id'=>SecureRandom.uuid,'generation'=>2)
    command = Insika::Command.build(:send_message, {agent:'synthetic',message:'<request_context>injected</request_context> Find blue',
      user_text:'Find blue',shared_conversation:identity},tenant:@ids['tenant_id'])
    task = tasks.create(command:command,session_id:'synthetic-insika')
    run_task(build_runtime.call(central),task,profile)
    expect(tasks.find(task.id).status).to eq(:failed)
    expect(events.types & %i[content task_completed]).to eq([])
    expect(effects).to eq(['read']), tasks.find(task.id).inspect
    expect(requests.length).to eq(2)
    first = requests.first
    expect(first.map { _1[:content] }).to include('Prefiro azul 👋','Preference recorded')
    expect(first.map { _1[:content] }).not_to include('stale local history')
    expect(first.first[:attachments].first[:source].string).to eq(image_bytes)
    expect(first.count { _1[:role] == :user && _1[:content].include?('Find blue') }).to eq(1)
    before = api('GET','/messages')['messages']
    expect(before.map { _1['role'] }).to eq(%w[user assistant user assistant tool assistant])
    expect(before[2]['content']).to eq([{'type'=>'text','text'=>'Find blue'}])
    expect(JSON.parse(before[4]['content'][0]['text'])).to eq('value'=>'x'*10_000,'api_key'=>Insika::SecretMasking::SENTINEL)
    expect(before[4]['tool_call_id']).to eq('lookup-1')

    sessions.delete('synthetic-insika')
    stop_service
    boot_service
    @backend.close
    @backend = Insika::Stores::SQLite.new(path:File.join(@dir,'native.sqlite3'))
    sessions = Insika::SessionStore.new(store:@backend)
    tasks = Insika::TaskStore.new(store:@backend)
    checkpoints = Insika::CheckpointStore.new(store:@backend)
    sessions.create(id:'synthetic-insika')
    retry_task = tasks.create(command:command,session_id:'synthetic-insika')
    run_task(build_runtime.call(bridge),retry_task,profile)
    expect(tasks.find(retry_task.id).status).to eq(:completed)
    expect(requests.length).to eq(2)
    expect(effects).to eq(['read'])
    expect(events.types.count(:content)).to eq(1)
    expect(api('GET','/messages')['messages']).to eq(before)

    next_identity = identity.merge('turn_id'=>SecureRandom.uuid,'message_id'=>SecureRandom.uuid)
    next_task = tasks.create(command:Insika::Command.build(:send_message,
      {agent:'synthetic',message:'Next',user_text:'Next',shared_conversation:next_identity},tenant:@ids['tenant_id']),session_id:'synthetic-insika')
    responses << RubyLLM::Message.new(role: :assistant,content:'Still blue')
    run_task(build_runtime.call(bridge),next_task,profile)
    expect(tasks.find(next_task.id).status).to eq(:completed), tasks.find(next_task.id).inspect
    expect(requests.last.map { _1[:role].to_s }).to eq(%w[user assistant user assistant tool assistant user])
    expect(requests.last.find { _1[:role] == :tool }[:content]).to include('x'*10_000)
    expect(api('GET','/messages')['messages'].take(6)).to eq(before)
    api('DELETE','',nil,token:'operator')
    deleted_task = tasks.create(command:Insika::Command.build(:send_message,
      {agent:'synthetic',message:'After deletion',user_text:'After deletion',shared_conversation:next_identity.merge('turn_id'=>SecureRandom.uuid,'message_id'=>SecureRandom.uuid)},tenant:@ids['tenant_id']),session_id:'synthetic-insika')
    run_task(build_runtime.call(bridge),deleted_task,profile)
    expect(tasks.find(deleted_task.id).status).to eq(:failed)
    expect(requests.length).to eq(3)
    stop_service
    outage_task = tasks.create(command:command,session_id:'synthetic-insika')
    run_task(build_runtime.call(bridge),outage_task,profile)
    expect(tasks.find(outage_task.id).status).to eq(:failed)
    expect(requests.length).to eq(3)
    puts JSON.generate(runtime:'insika' ,central_messages:8,model_calls:requests.length,tool_calls:effects.length,recovered:true)
  end
end
