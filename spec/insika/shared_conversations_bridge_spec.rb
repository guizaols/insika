# frozen_string_literal: true
require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Shared conversation HTTP bridge' do
  around do |example|
    Dir.mktmpdir('shared-insika-') do |dir|
      @backend = Insika::Stores::SQLite.new(path: File.join(dir, 'native.sqlite3'))
      example.run
    ensure
      @backend&.close
    end
  end
  let(:ids) { %w[tenant_id user_id agent_id conversation_id turn_id message_id].to_h { [_1, SecureRandom.uuid] }.merge('generation'=>1) }
  let(:profile) { Insika::AgentProfile.build(id: 'test', shared_conversations: true) }
  let(:task) do
    Insika::TaskStore.new(store: @backend).create(session_id: 'native-test', command:
      Insika::Command.build(:send_message, {shared_conversation: ids, user_text: 'original speech', message: '<context>secret prompt</context> original speech'}, tenant: ids['tenant_id']))
  end
  let(:bridge) { Insika::SharedConversations.new(url: 'http://127.0.0.1:9292', token: 'test', store: @backend) }
  let(:conversation) { ids.slice('tenant_id','user_id','agent_id').merge('assigned_harness'=>'insika','generation'=>1,'last_sequence'=>0,'active_turn'=>nil) }
  let(:calls) { [] }
  before do
    allow(bridge).to receive(:request) do |method, path, data = nil, **_options|
      calls << [method,path,data]
      case path
      when /\/memories\/conversation\// then {'memories'=>[]}
      when /\/messages\?/ then {'messages'=>[], 'through_sequence'=>0, 'next_sequence'=>0}
      when /\/native-run$/ then {'native_run_id'=>task.id,'state'=>'running'}
      when /\/turns$/ then {'id'=>ids['turn_id'],'state'=>'running','native_run_id'=>nil}
      when /\/complete$/ then {'state'=>'completed'}
      when /\/messages$/ then {'last_sequence'=>3}
      when /\/bindings\// then {}
      else conversation
      end
    end
  end

  it 'namespaces historical tool IDs by turn before RubyLLM checks answered calls' do
    turns = 2.times.map { SecureRandom.uuid }
    history = turns.flat_map { |turn| [
      {'turn_id'=>turn,'role'=>'assistant','content'=>[],'tool_calls'=>[{'id'=>'remember-call','name'=>'remember','arguments'=>{}}]},
      {'turn_id'=>turn,'role'=>'tool','content'=>[],'tool_call_id'=>'remember-call'}] }
    projected = bridge.send(:project, history, '/unused')
    ids = projected.select { _1['tool_calls'] }.map { _1['tool_calls'].first['id'] }
    expect(ids.uniq.size).to eq(2)
    expect(ids).not_to include('remember-call')
    expect(projected.filter_map { _1['tool_call_id'] }).to eq(ids)
    expect(history.last['tool_call_id']).to eq('remember-call')
  end

  it 'reserves original speech before registering execution and ignores local history' do
    expect(bridge.begin_turn(task: task, profile: profile)).to eq([])
    input = calls.find { _1[1].end_with?('/turns') }.last.fetch('message')
    expect(input['content']).to eq([{'type'=>'text','text'=>'original speech'}])
    expect(calls.map { _1[1] }.last).to end_with('/native-run')
    expect(input['id']).to eq(ids['message_id'])
  end

  it 'refuses mismatched identity before reservation or model work' do
    conversation['user_id'] = SecureRandom.uuid
    expect { bridge.begin_turn(task: task, profile: profile) }.to raise_error(Insika::StoreError, /identity/)
    expect(calls.none? { _1[1].end_with?('/turns') }).to eq(true)
  end

  it 'retains the exact native result after a lost completion acknowledgment' do
    bridge.begin_turn(task: task, profile: profile)
    final = [{'role'=>'user','content'=>'injected'}, {'role'=>'assistant','content'=>'answer'}]
    completion_bodies = []
    allow(bridge).to receive(:request).with('POST', /\/complete$/, anything) do |_method,_path,body|
      completion_bodies << body
      raise Insika::StoreError, 'lost acknowledgment' if completion_bodies.length == 1
      {'state'=>'completed'}
    end
    expect { bridge.complete(task: task, messages: final) }.to raise_error(Insika::StoreError)
    expect { bridge.begin_turn(task: task, profile: profile) }.to raise_error(Insika::SharedConversations::Recovered) { expect(_1.content).to eq('answer') }
    expect(completion_bodies.size).to eq(2)
    expect(completion_bodies[0]).to eq(completion_bodies[1])
  end

  it 'archives full tool results with secret keys masked before prompt clipping' do
    bridge.begin_turn(task: task, profile: profile)
    bridge.record_tool_result(task: task, call_id: 'lookup', result: {'value'=>'x'*10_000, 'api_key'=>'private'})
    bridge.complete(task: task, messages: [
      {'role'=>'user','content'=>'original speech'},
      {'role'=>'assistant','content'=>'','tool_calls'=>[{'id'=>'lookup','name'=>'search','arguments'=>{}}]},
      {'role'=>'tool','tool_call_id'=>'lookup','content'=>'clipped'},
      {'role'=>'assistant','content'=>'answer'}])
    archived = calls.find { _1[0] == 'POST' && _1[1].end_with?('/messages') }.last['messages'][1]
    body = JSON.parse(archived['content'][0]['text'])
    expect(body['value']).to eq('x'*10_000)
    expect(body['api_key']).to eq(Insika::SecretMasking::SENTINEL)
  end

  it 'uploads generated bytes before completion and preserves attachment IDs on retry' do
    require 'base64'
    bridge.begin_turn(task: task, profile: profile)
    parts = [{'type'=>'audio','mime_type'=>'audio/mpeg','base64'=>Base64.strict_encode64('synthetic audio')}]
    bridge.complete(task: task, messages: [{'role'=>'assistant','content'=>'Listen'}], output_parts: parts)
    upload = calls.find { _1[0] == 'PUT' && _1[1].include?('/attachments/') }
    expect(upload.last).to eq('synthetic audio')
    final = calls.find { _1[1].end_with?('/complete') }.last['message']
    expect(final['content'].last).to eq('type'=>'audio','attachment_id'=>upload[1].split('/').last)
    expect { bridge.begin_turn(task: task, profile: profile) }.to raise_error(Insika::SharedConversations::Recovered) { expect(_1.output_parts).to eq(parts) }
    uploads = calls.select { _1[0] == 'PUT' && _1[1].include?('/attachments/') }
    expect(uploads[0]).to eq(uploads[1])
  end

  it 'allows only the same waiting native approval to resume under the current generation' do
    bridge.begin_turn(task: task, profile: profile)
    conversation['active_turn'] = {'id'=>ids['turn_id'],'native_run_id'=>task.id,'state'=>'running'}
    waiting = task.with(status: :waiting)
    checkpoint = Insika::Checkpoint.new(task_id: task.id, turn: 1, session_id: task.session_id,
      agent_id: profile.id, messages: [], completed_side_effects: [], created_at: Time.now.utc.iso8601, continuation: {'messages'=>[]})
    expect(bridge.resume_turn(task: waiting, profile: profile, checkpoint: checkpoint)).to eq([])
    conversation['generation'] = 2
    expect { bridge.resume_turn(task: waiting, profile: profile, checkpoint: checkpoint) }.to raise_error(Insika::StoreError, /identity|generation/)
  end

  it 'blocks an uncertain native execution instead of generating a second answer' do
    bridge.begin_turn(task: task, profile: profile)
    expect { bridge.begin_turn(task: task, profile: profile) }.to raise_error(Insika::StoreError, /reconciliation/)
  end
  it 'reads canonical user facts and proposes edits with central revision and message provenance' do
    prefix = "/v1/memories/user/#{ids['user_id']}"
    record = {'id'=>'size','value'=>'M','kind'=>'fact','revision'=>2,'origin'=>'operator'}
    allow(bridge).to receive(:request).with('GET',prefix+'?limit=50').and_return({'memories'=>[{'id'=>'size'}]})
    allow(bridge).to receive(:request).with('GET',prefix+'/size',missing:true).and_return(record)
    expect(bridge.memory_context(task:task,profile:profile.with(memory:true))['facts']).to eq([record])
    allow(bridge).to receive(:request).with('GET',prefix+'/size?include_proposed=true',missing:true).and_return(record)
    expect(bridge).to receive(:request).with('PUT',prefix+'/size',hash_including(
      'expected_revision'=>2,'status'=>'proposed','origin'=>'insika',
      'sources'=>[ids.slice('conversation_id').merge('message_id'=>ids['message_id'])]))
    bridge.propose_memory(task:task,id:'size',value:'L')
  end

end
