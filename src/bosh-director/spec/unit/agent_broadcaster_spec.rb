require 'spec_helper'
require 'timecop'

module Bosh::Director
  describe AgentBroadcaster do

    after { Timecop.return }

    let(:ip_addresses) { ['10.0.0.1'] }
    let(:instance1) do
      instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 1, job: 'fake-job-1')
      Bosh::Director::Models::Vm.make(id: 1, agent_id: 'agent-1', cid: 'id-1', instance_id: instance.id, active: true)
      instance
    end
    let(:instance2) do
      instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 2, job: 'fake-job-1')
      Bosh::Director::Models::Vm.make(id: 2, agent_id: 'agent-2', cid: 'id-2', instance_id: instance.id, active: true)
      instance
    end
    let(:agent) { instance_double(AgentClient, wait_until_ready: nil, delete_arp_entries: nil) }
    let(:agent2) { instance_double(AgentClient, wait_until_ready: nil, delete_arp_entries: nil) }
    let(:agent_broadcast) { AgentBroadcaster.new(0.1) }

    describe '#filter_instances' do
      it 'excludes the VM being created' do
        3.times do |i|
          Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: i, job: "fake-job-#{i}")
        end

        instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 0, job: 'fake-job-0')
        vm_being_created = Bosh::Director::Models::Vm.make(id: 11, cid: 'fake-cid-0', instance_id: instance.id, active: true)

        agent_broadcast = AgentBroadcaster.new
        instances = agent_broadcast.filter_instances(vm_being_created.cid)

        expect(instances.count).to eq 0
      end

      it 'excludes instances where the vm is nil' do
        3.times do |i|
          Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: i, job: "fake-job-#{i}")
        end
        vm_being_created_cid = 'fake-cid-99'

        agent_broadcast = AgentBroadcaster.new
        instances = agent_broadcast.filter_instances(vm_being_created_cid)

        expect(instances.count).to eq 0
      end

      it 'excludes compilation VMs' do
        instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 0, job: 'fake-job-0', compilation: true)
        active_vm = Bosh::Director::Models::Vm.make(id: 11, cid: 'fake-cid-0', instance: instance, active: true)
        vm_being_created_cid = 'fake-cid-99'

        agent_broadcast = AgentBroadcaster.new
        instances = agent_broadcast.filter_instances(vm_being_created_cid)

        expect(instances.count).to eq 0
      end

      it 'includes VMs that need flushing' do
        instance = Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, index: 0, job: 'fake-job-0')
        active_vm = Bosh::Director::Models::Vm.make(id: 11, cid: 'fake-cid-0', instance: instance, active: true)
        vm_being_created_cid = 'fake-cid-99'

        agent_broadcast = AgentBroadcaster.new
        instances = agent_broadcast.filter_instances(vm_being_created_cid)

        expect(instances.map {|i| i[:id]}).to eq [instance[:id]]
      end
    end

    describe '#delete_arp_entries' do
      it 'successfully broadcast :delete_arp_entries call' do
        expect(AgentClient).to receive(:with_agent_id).
          with(instance1.agent_id, instance1.name).and_return(agent)
        expect(agent).to receive(:delete_arp_entries).with(ips: ip_addresses)

        agent_broadcast.delete_arp_entries('fake-vm-cid-to-exclude', ip_addresses)
      end

      it 'successfully filers out id-1 and broadcast :delete_arp_entries call' do
        expect(AgentClient).to receive(:with_agent_id)
          .with(instance1.agent_id, instance1.name).and_return(agent)
        expect(AgentClient).to_not receive(:with_agent_id)
          .with(instance2.agent_id, instance2.name)
        expect(agent).to receive(:delete_arp_entries).with(ips: ip_addresses)

        agent_broadcast.delete_arp_entries('id-2', ip_addresses)
      end
    end

    describe '#sync_dns' do
      let(:start_time) { Time.now }
      let(:end_time) { start_time + 0.01 }
      let(:reactor) {instance_double(EmReactorLoop)}

      before do
        Timecop.freeze(start_time)

        allow(EmReactorLoop).to receive(:new).and_return(reactor)

        allow(reactor).to(receive(:queue)) { |&blk| blk.call }
      end

      context 'when all agents are responsive' do
        it 'successfully broadcast :sync_dns call' do
          expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: sending to 2 agents ["agent-1", "agent-2"]')
          expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: attempted 2 agents in 10ms (2 successful, 0 failed, 0 unresponsive)')

          expect(AgentClient).to receive(:with_agent_id)
            .with(instance1.agent_id, instance1.name).and_return(agent)

          expect(agent).to receive(:sync_dns).with('fake-blob-id', 'fake-sha1', 1) do |&blk|
            blk.call({'value' => 'synced'})
            Timecop.freeze(end_time)
          end.and_return('instance-1-req-id')

          expect(AgentClient).to receive(:with_agent_id)
            .with(instance2.agent_id, instance2.name).and_return(agent2)

          expect(agent2).to receive(:sync_dns).with('fake-blob-id', 'fake-sha1', 1) do |&blk|
            blk.call({'value' => 'synced'})
          end.and_return('instance-2-req-id')

          agent_broadcast.sync_dns(agent_broadcast.filter_instances(nil), 'fake-blob-id', 'fake-sha1', 1)

          expect(Models::AgentDnsVersion.all.length).to eq(2)
        end
      end

      context 'when some agents fail' do
        let!(:instances) { [instance1, instance2]}

        context 'and agent succeeds within retry count' do
          it 'retries broadcasting to failed agents' do
            expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: sending to 2 agents ["agent-1", "agent-2"]')
            expect(logger).to receive(:error).with('agent_broadcaster: sync_dns[agent-2]: received unexpected response {"value"=>"unsynced"}')
            expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: attempted 2 agents in 10ms (1 successful, 1 failed, 0 unresponsive)')

            expect(AgentClient).to receive(:with_agent_id).
              with(instance1.agent_id, instance1.name) do
              expect(agent).to receive(:sync_dns) do |&blk|
                blk.call({'value' => 'synced'})
                Timecop.freeze(end_time)
              end
              agent
            end

            expect(AgentClient).to receive(:with_agent_id).
              with(instance2.agent_id, instance2.name) do
              expect(agent).to receive(:sync_dns) do |&blk|
                blk.call({'value' => 'unsynced'})
              end
              agent
            end

            agent_broadcast.sync_dns(agent_broadcast.filter_instances(nil), 'fake-blob-id', 'fake-sha1', 1)

            expect(Models::AgentDnsVersion.all.length).to eq(1)
          end
        end
      end

      context 'that we are able to update the AgentDnsVersion' do
        let!(:instances) { [instance1]}

        before do
          expect(AgentClient).to receive(:with_agent_id) do
            expect(agent).to receive(:sync_dns) do |&blk|
              blk.call({'value' => 'synced'})
              Timecop.freeze(end_time)
            end
            agent
          end
        end

        context 'when there are no prior existing records for the instances' do
          it 'will create new records for the instances' do
            agent_broadcast.sync_dns(agent_broadcast.filter_instances(nil), 'fake-blob-id', 'fake-sha1', 42)

            expect(Models::AgentDnsVersion.all.length).to eq(1)
            expect(Models::AgentDnsVersion.all[0].dns_version).to equal(42)
          end
        end

        context 'when we need to update existing records for the instances' do
          before do
            Models::AgentDnsVersion.create(agent_id: instance1.agent_id, dns_version: 1)
          end

          it 'will update records for the instances' do
            agent_broadcast.sync_dns(agent_broadcast.filter_instances(nil), 'fake-blob-id', 'fake-sha1', 42)

            expect(Models::AgentDnsVersion.all.length).to eq(1)
            expect(Models::AgentDnsVersion.all[0].dns_version).to equal(42)
          end
        end

        context 'when another thread would have inserted the instance at the same time' do
          before do
            # placeholder since we override the create method in the next line
            version = Models::AgentDnsVersion.create(agent_id: 'fake-agent', dns_version: 1)

            expect(Models::AgentDnsVersion).to receive(:create) do
              # pretend another parallel process inserted an agent record in the db to emulate the race
              version.agent_id = instance1.agent_id
              version.save

              raise Sequel::UniqueConstraintViolation
            end
          end

          it 'will still be able to update the AgentDnsVersion records' do
            agent_broadcast.sync_dns(agent_broadcast.filter_instances(nil), 'fake-blob-id', 'fake-sha1', 42)

            expect(Models::AgentDnsVersion.all[0].dns_version).to equal(42)
          end
        end
      end

      context 'when some agents are unresponsive' do
        let!(:instances) { [instance1, instance2]}

        context 'and agent succeeds within retry count' do
          it 'logs broadcasting fail to failed agents' do
            expect(logger).to receive(:info).with('agent_broadcaster: sync_dns: sending to 2 agents ["agent-1", "agent-2"]')
            expect(logger).to receive(:warn).with('agent_broadcaster: sync_dns: no response received for 1 agent(s): [agent-2]')
            expect(logger).to receive(:info).with(/agent_broadcaster: sync_dns: attempted 2 agents in \d+ms \(1 successful, 0 failed, 1 unresponsive\)/)

            expect(AgentClient).to receive(:with_agent_id).
              with(instance1.agent_id, instance1.name) do
              expect(agent).to receive(:sync_dns) do |&blk|
                blk.call({'value' => 'synced'})
                Timecop.travel(end_time)
              end.and_return('sync_dns_request_id_1')
              agent
            end

            expect(AgentClient).to receive(:with_agent_id).
              with(instance2.agent_id, instance2.name) do
              expect(agent).to receive(:sync_dns).and_return('sync_dns_request_id_2')
              agent
            end.once

            expect(AgentClient).to receive(:with_agent_id).
              with(instance2.agent_id, instance2.name) do
              expect(agent).to receive(:cancel_sync_dns).with('sync_dns_request_id_2')
              agent
            end.once

            agent_broadcast.sync_dns(agent_broadcast.filter_instances(nil), 'fake-blob-id', 'fake-sha1', 1)

            expect(Models::AgentDnsVersion.all.length).to eq(1)
          end
        end
      end

      context 'only after all messages have been sent off' do
        it 'starts the timeout timer' do
          allow(reactor).to receive(:queue) do |&blk|
            RSpec::Mocks.space.proxy_for(Timeout).reset
            expect(Timeout).to receive(:new).and_call_original
            blk.call
          end

          expect(Timeout).to_not receive(:new)

          allow(AgentClient).to receive(:with_agent_id) do
            allow(agent).to receive(:sync_dns) do |&blk|
              blk.call({'value' => 'synced'})
            end
            agent
          end

          agent_broadcast.sync_dns(agent_broadcast.filter_instances('id-2'), 'fake-blob-id', 'fake-sha1', 1)
        end
      end
    end
  end
end
