require 'spec_helper'
require 'bosh/director/models/vm'

module Bosh::Director::Models
  describe Vm do
    subject(:vm) { BD::Models::Vm.make(instance: instance) }

    let!(:instance) { BD::Models::Instance.make }

    it 'has a many-to-one relationship to instances' do
      described_class.make(instance_id: instance.id, id: 1)
      described_class.make(instance_id: instance.id, id: 2)

      expect(described_class.find(id: 1).instance).to eq(instance)
      expect(described_class.find(id: 2).instance).to eq(instance)
    end

    describe '#network_spec' do
      it 'unmarshals network_spec_json' do
        vm.network_spec_json = JSON.dump({'some' => 'spec'})

        expect(vm.network_spec).to eq({'some' => 'spec'})
      end

      context 'when network_spec_json is nil' do
        it 'returns empty hash' do
          vm.network_spec_json = nil

          expect(vm.network_spec).to eq({})
        end
      end
    end

    describe '#network_spec=' do
      it 'sets network_spec_json with json-ified value' do
        vm.network_spec = {'some' => 'spec'}

        expect(vm.network_spec_json).to eq(JSON.dump({'some' => 'spec'}))
      end
    end
  end
end
