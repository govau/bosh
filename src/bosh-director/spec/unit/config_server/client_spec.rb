require 'spec_helper'

module Bosh::Director::ConfigServer

  describe EnabledClient do
    subject(:client) { EnabledClient.new(http_client, director_name, logger) }
    let(:director_name) {'smurf_director_name'}
    let(:deployment_name) {'deployment_name'}
    let(:logger) { double('Logging::Logger') }
    let!(:deployment_model) { Bosh::Director::Models::Deployment.make(name: deployment_name) }

    def prepend_namespace(name)
      "/#{director_name}/#{deployment_name}/#{name}"
    end

    before do
      allow(logger).to receive(:info)
    end

    describe '#interpolate' do
      subject { client.interpolate(manifest_hash, deployment_name, interpolate_options) }
      let(:interpolate_options) do
        {
          :subtrees_to_ignore => ignored_subtrees
        }
      end
      let(:ignored_subtrees) {[]}
      let(:nil_placeholder) { {'data' => [{'name' => "#{prepend_namespace('nil_placeholder')}", 'value' => nil, 'id' => '1'}]} }
      let(:empty_placeholder) { {'data' => [{'name' => "#{prepend_namespace('empty_placeholder')}", 'value' => '', 'id' => '2'}]} }
      let(:integer_placeholder) { {'data' => [{'name' => "#{prepend_namespace('integer_placeholder')}", 'value' => 123, 'id' => '3'}]} }
      let(:instance_placeholder) { {'data' => [{'name' => "#{prepend_namespace('instance_placeholder')}", 'value' => 'test1', 'id' => '4'}]} }
      let(:job_placeholder) { {'data' => [{'name' => "#{prepend_namespace('job_placeholder')}", 'value' => 'test2', 'id' => '5'}]} }
      let(:env_placeholder) { {'data' => [{'name' => "#{prepend_namespace('env_placeholder')}", 'value' => 'test3', 'id' => '6'}]} }
      let(:cert_placeholder) { {'data' => [{'name' => "#{prepend_namespace('cert_placeholder')}", 'value' => {'ca' => 'ca_value', 'private_key'=> 'abc123'}, 'id' => '7'}]} }
      let(:mock_config_store) do
        {
          prepend_namespace('nil_placeholder') => generate_success_response(nil_placeholder.to_json),
          prepend_namespace('empty_placeholder') => generate_success_response(empty_placeholder.to_json),
          prepend_namespace('integer_placeholder') => generate_success_response(integer_placeholder.to_json),
          prepend_namespace('instance_placeholder') => generate_success_response(instance_placeholder.to_json),
          prepend_namespace('job_placeholder') => generate_success_response(job_placeholder.to_json),
          prepend_namespace('env_placeholder') => generate_success_response(env_placeholder.to_json),
          prepend_namespace('cert_placeholder') => generate_success_response(cert_placeholder.to_json),
        }
      end

      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }
      let(:manifest_hash)  do
        {
          'name' => deployment_name,
          'properties' => {
            'name' => '((integer_placeholder))',
            'nil_allowed' => '((nil_placeholder))',
            'empty_allowed' => '((empty_placeholder))'
          },
          'instance_groups' =>           {
            'name' => 'bla',
            'jobs' => [
              {
                'name' => 'test_job',
                'properties' => { 'job_prop' => '((job_placeholder))' }
              }
            ]
          },
          'resource_pools' => [
            {'env' => {'env_prop' => '((env_placeholder))'} }
          ],
          'cert' => '((cert_placeholder))'
        }
      end

      before do
        mock_config_store.each do |name, value|
          allow(http_client).to receive(:get).with(name).and_return(value)
        end
      end

      context 'when response received from server is not in the expected format' do
        let(:manifest_hash) do
          {
              'name' => 'deployment_name',
              'properties' => {
                  'name' => '((/bad))'
              }
          }
        end

        it 'raises an error' do
          data = [
              {'response' => 'Invalid JSON response',
               'message' => '- Failed to fetch variable \'/bad\' from config server: Invalid JSON response'},

              {'response' => {'x' => {}},
               'message' => '- Failed to fetch variable \'/bad\' from config server: Expected data to be an array'},

              {'response' => {'data' => {'value' => 'x'}},
               'message' => '- Failed to fetch variable \'/bad\' from config server: Expected data to be an array'},

              {'response' => {'data' => []},
               'message' => '- Failed to fetch variable \'/bad\' from config server: Expected data to be non empty array'},

              {'response' => {'data' => [{'val' => 'x'}]},
               'message' => '- Failed to fetch variable \'/bad\' from config server: Expected data[0] to have key \'value\''},
          ]

          data.each do |entry|
            allow(http_client).to receive(:get).with('/bad').and_return(generate_success_response(entry['response'].to_json))

            expect {
              subject
            }.to raise_error { |error|
              expect(error).to be_a(Bosh::Director::ConfigServerFetchError)
              expect(error.message).to include(entry['message'])
            }
          end
        end
      end

      context 'when response received from server has multiple errors' do
        let(:manifest_hash) do
          {
              'name' => 'deployment_name',
              'properties' => {
                  'p1' => '((/bad1))',
                  'p2' => '((/bad2))',
                  'p3' => '((/bad3))',
                  'p4' => '((/bad4))',
                  'p5' => '((/bad5))',
              }
          }
        end

        let(:mock_config_store) do
          {
              '/bad1' => generate_success_response('Invalid JSON response'),
              '/bad2' => generate_success_response({'x' => {}}.to_json),
              '/bad3' => generate_success_response({'data' => {'value' => 'x'}}.to_json),
              '/bad4' => generate_success_response({'data' => []}.to_json),
              '/bad5' => generate_success_response({'data' => [{'val' => 'x'}]}.to_json),
          }
        end

        it 'raises an error consolidating all the problems' do
          expect {
            subject
          }.to raise_error { |error|
              expect(error).to be_a(Bosh::Director::ConfigServerFetchError)
              expect(error.message).to include("- Failed to fetch variable '/bad1' from config server: Invalid JSON response")
              expect(error.message).to include("- Failed to fetch variable '/bad2' from config server: Expected data to be an array")
              expect(error.message).to include("- Failed to fetch variable '/bad3' from config server: Expected data to be an array")
              expect(error.message).to include("- Failed to fetch variable '/bad4' from config server: Expected data to be non empty array")
              expect(error.message).to include("- Failed to fetch variable '/bad5' from config server: Expected data[0] to have key 'value'")
          }
        end
      end

      context 'when absolute path is required' do
        it 'should raise error when name is not absolute' do
          expect{
            client.interpolate(manifest_hash, deployment_name, {subtrees_to_ignore: ignored_subtrees, must_be_absolute_name: true})
          }.to raise_error(Bosh::Director::ConfigServerIncorrectNameSyntax)
        end
      end

      it 'should return a new copy of the original manifest' do
        expect(client.interpolate(manifest_hash, deployment_name, {subtrees_to_ignore: ignored_subtrees})).to_not equal(manifest_hash)
      end

      it 'replaces all placeholders it finds in the hash passed' do
        expected_result = {
          'name' => 'deployment_name',
          'properties' => {
            'name' => 123,
            'nil_allowed' => nil,
            'empty_allowed' => ''
          },
          'instance_groups' => {
            'name' => 'bla',
            'jobs' => [
              {
                'name' => 'test_job',
                'properties' => { 'job_prop' => 'test2' }
              }
            ]
          },
          'resource_pools' => [
            {'env' => {'env_prop' => 'test3'} }
          ],
          'cert' => {
              'ca' => 'ca_value',
              'private_key'=> 'abc123'
          }
        }

        expect(subject).to eq(expected_result)
      end

      it 'should raise a missing name error message when name is not found in the config_server' do
        allow(http_client).to receive(:get).with(prepend_namespace('missing_placeholder')).and_return(SampleNotFoundResponse.new)

        manifest_hash['properties'] = { 'name' => '((missing_placeholder))' }
        expect{
          subject
        }.to raise_error { |error|
          expect(error).to be_a(Bosh::Director::ConfigServerFetchError)
          expect(error.message).to include("- Failed to find variable '#{prepend_namespace('missing_placeholder')}' from config server: HTTP code '404'")
        }
      end

      it 'should raise an unknown error when config_server returns any error other than a 404' do
        allow(http_client).to receive(:get).with(prepend_namespace('missing_placeholder')).and_return(SampleForbiddenResponse.new)

        manifest_hash['properties'] = { 'name' => '((missing_placeholder))' }
        expect{
          subject
        }.to raise_error { |error|
          expect(error).to be_a(Bosh::Director::ConfigServerFetchError)
          expect(error.message).to include("- Failed to fetch variable '/smurf_director_name/deployment_name/missing_placeholder' from config server: HTTP code '403'")
        }
      end

      context 'ignored subtrees' do
        #TODO pull out config server mocks into their own lets
        let(:mock_config_store) do
          {
            prepend_namespace('release_1_placeholder') => generate_success_response({'data'=>[{'value' => 'release_1', 'id' => 1}]}.to_json),
            prepend_namespace('release_2_version_placeholder') => generate_success_response({'data'=>[{'value' => 'v2', 'id' => 2}]}.to_json),
            prepend_namespace('job_name') => generate_success_response({'data'=>[{'value' => 'spring_server', 'id' => 3}]}.to_json)
          }
        end

        let(:manifest_hash) do
          {
            'releases' => [
              {'name' => '((release_1_placeholder))', 'version' => 'v1'},
              {'name' => 'release_2', 'version' => '((release_2_version_placeholder))'}
            ],
            'instance_groups' => [
              {
                'name' => 'logs',
                'env' => { 'smurf' => '((smurf_placeholder))' },
                'jobs' => [
                  {
                    'name' => 'mysql',
                    'properties' => {'foo' => '((foo_place_holder))', 'bar' => {'smurf' => '((smurf_placeholder))'}}
                  },
                  {
                    'name' => '((job_name))'
                  }
                ],
                'properties' => {'a' => ['123', 45, '((secret_name))']}
              }
            ],
            'properties' => {
              'global_property' => '((something))'
            },
            'resource_pools' => [
              {
                'name' => 'resource_pool_name',
                'env' => {
                  'f' => '((f_placeholder))'
                }
              }
            ]
          }
        end

        let(:interpolated_manifest_hash) do
          {
            'releases' => [
              {'name' => 'release_1', 'version' => 'v1'},
              {'name' => 'release_2', 'version' => 'v2'}
            ],
            'instance_groups' => [
              {
                'name' => 'logs',
                'env' => {'smurf' => '((smurf_placeholder))'},
                'jobs' => [
                  {
                    'name' => 'mysql',
                    'properties' => {'foo' => '((foo_place_holder))', 'bar' => {'smurf' => '((smurf_placeholder))'}}
                  },
                  {
                    'name' => 'spring_server'
                  }
                ],
                'properties' => {'a' => ['123', 45, '((secret_name))']}
              }
            ],
            'properties' => {
              'global_property' => '((something))'
            },
            'resource_pools' => [
              {
                'name' => 'resource_pool_name',
                'env' => {
                  'f' => '((f_placeholder))'
                }
              }
            ]
          }
        end

        let(:ignored_subtrees) do
          index_type = Integer
          any_string = String

          ignored_subtrees = []
          ignored_subtrees << ['properties']
          ignored_subtrees << ['instance_groups', index_type, 'properties']
          ignored_subtrees << ['instance_groups', index_type, 'jobs', index_type, 'properties']
          ignored_subtrees << ['instance_groups', index_type, 'jobs', index_type, 'consumes', any_string, 'properties']
          ignored_subtrees << ['jobs', index_type, 'properties']
          ignored_subtrees << ['jobs', index_type, 'templates', index_type, 'properties']
          ignored_subtrees << ['jobs', index_type, 'templates', index_type, 'consumes', any_string, 'properties']
          ignored_subtrees << ['instance_groups', index_type, 'env']
          ignored_subtrees << ['jobs', index_type, 'env']
          ignored_subtrees << ['resource_pools', index_type, 'env']
          ignored_subtrees << ['name']
          ignored_subtrees
        end

        it 'should not replace values in ignored subtrees' do
          expect(subject).to eq(interpolated_manifest_hash)
        end
      end

      context 'when placeholders use dot syntax' do

        let(:nested_placeholder) do
          {
              'data' => [
                  {
                      'name' => "#{prepend_namespace('nested_placeholder')}",
                      'value' => { 'x' => { 'y' => { 'z' => 'gold' } } }
                  }
              ]
          }
        end

        let(:mock_config_store) do
          {
              '/nested_placeholder' => generate_success_response(nested_placeholder.to_json)
          }
        end

        let(:manifest_hash)  do
          {
              'nest1' => '((/nested_placeholder.x))',
              'nest2' => '((/nested_placeholder.x.y))',
              'nest3' => '((/nested_placeholder.x.y.z))'
          }
        end

        it 'should only use the first piece of the placeholder name when making requests to the config_server' do
          expect(http_client).to receive(:get).with('/nested_placeholder')
          subject
        end

        it 'should return the sub-property' do
          expected_result = {
              'nest1' => { 'y' => { 'z' => 'gold' } },
              'nest2' => { 'z' => 'gold' },
              'nest3' => 'gold'
          }
          expect(subject).to eq(expected_result)
        end

        context 'when all parts of dot syntax are not found' do

          let(:manifest_hash) do
            {
                'name' => 'deployment_name',
                'bad_nest' => ''
            }
          end

          it 'raises an error' do
            data = [
                {'placeholder' => '((/nested_placeholder.a))',
                 'message' => "- Failed to fetch variable '/nested_placeholder' from config server: Expected parent '/nested_placeholder' hash to have key 'a'"},

                {'placeholder' => '((/nested_placeholder.a.b))',
                 'message' => "- Failed to fetch variable '/nested_placeholder' from config server: Expected parent '/nested_placeholder' hash to have key 'a'"},

                {'placeholder' => '((/nested_placeholder.x.y.a))',
                 'message' => "- Failed to fetch variable '/nested_placeholder' from config server: Expected parent '/nested_placeholder.x.y' hash to have key 'a'"},

                {'placeholder' => '((/nested_placeholder.x.a.y))',
                 'message' => "- Failed to fetch variable '/nested_placeholder' from config server: Expected parent '/nested_placeholder.x' hash to have key 'a'"},
            ]

            data.each do | entry |
              manifest_hash['bad_nest'] = entry['placeholder']
              expect{
                subject
              }.to raise_error { |error|
                expect(error).to be_a(Bosh::Director::ConfigServerFetchError)
                expect(error.message).to include(entry['message'])
              }
            end
          end
        end

        context 'when multiple errors occur because of parts of dot syntax not found' do
          let(:manifest_hash) do
            {
                'name' => 'deployment_name',
                'properties' => {
                    'p1' => '((/nested_placeholder.a))',
                    'p2' => '((/nested_placeholder.x.y.a))',
                    'p3' => '((/nested_placeholder.x.a.y))',
                }
            }
          end

          it 'raises an error consolidating all the problems' do
            expect {
              subject
            }.to raise_error { |error|
              expect(error).to be_a(Bosh::Director::ConfigServerFetchError)
              expect(error.message).to include("- Failed to fetch variable '/nested_placeholder' from config server: Expected parent '/nested_placeholder' hash to have key 'a'")
              expect(error.message).to include("- Failed to fetch variable '/nested_placeholder' from config server: Expected parent '/nested_placeholder.x.y' hash to have key 'a'")
              expect(error.message).to include("- Failed to fetch variable '/nested_placeholder' from config server: Expected parent '/nested_placeholder.x' hash to have key 'a'")
            }
          end
        end

        context 'when bad dot syntax is used' do
          let(:manifest_hash) do
            { 'bad_nest' => '((nested_placeholder..x))' }
          end

          it 'raises an error' do
            expect{
              subject
            }. to raise_error(Bosh::Director::ConfigServerIncorrectNameSyntax, "Placeholder name 'nested_placeholder..x' syntax error: Must not contain consecutive dots")
          end
        end
      end

      context 'when placeholders begin with !' do
        let(:manifest_hash) do
          {
            'name' => 'deployment_name',
            'properties' => {
              'age' => '((!integer_placeholder))'
            }
          }
        end

        it 'should strip the exclamation mark' do
          expected_result = {
            'name' => 'deployment_name',
            'properties' => {'age' => 123 }
          }
          expect(subject).to eq(expected_result)
        end
      end

      context 'when some placeholders have invalid name syntax' do
        let(:manifest_hash) do
          {
            'properties' => {
              'age' => '((I am an invalid name &%^))'
            }
          }
        end

        it 'raises an error' do
          expect{
            subject
          }. to raise_error(Bosh::Director::ConfigServerIncorrectNameSyntax)
        end
      end
    end

    describe '#interpolate_deployment_manifest' do
      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }

      let(:ignored_subtrees) do
        index_type = Integer
        any_string = String

        ignored_subtrees = []
        ignored_subtrees << ['properties']
        ignored_subtrees << ['instance_groups', index_type, 'properties']
        ignored_subtrees << ['instance_groups', index_type, 'jobs', index_type, 'properties']
        ignored_subtrees << ['instance_groups', index_type, 'jobs', index_type, 'consumes', any_string, 'properties']
        ignored_subtrees << ['jobs', index_type, 'properties']
        ignored_subtrees << ['jobs', index_type, 'templates', index_type, 'properties']
        ignored_subtrees << ['jobs', index_type, 'templates', index_type, 'consumes', any_string, 'properties']
        ignored_subtrees << ['instance_groups', index_type, 'env']
        ignored_subtrees << ['jobs', index_type, 'env']
        ignored_subtrees << ['resource_pools', index_type, 'env']
        ignored_subtrees
      end

      it 'should call interpolate with the correct arguments' do
        expect(subject).to receive(:interpolate).with({'name' => 'smurf', 'properties' => { 'a' => '{{placeholder}}' }}, 'smurf', {subtrees_to_ignore: ignored_subtrees, must_be_absolute_name: false}).and_return({'name' => 'smurf'})
        result = subject.interpolate_deployment_manifest({'name' => 'smurf', 'properties' => { 'a' => '{{placeholder}}' } })
        expect(result).to eq({'name' => 'smurf'})
      end
    end

    describe '#interpolate_runtime_manifest' do
      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }

      let(:ignored_subtrees) do
        index_type = Integer
        any_string = String

        ignored_subtrees = []
        ignored_subtrees << ['addons', index_type, 'properties']
        ignored_subtrees << ['addons', index_type, 'jobs', index_type, 'properties']
        ignored_subtrees << ['addons', index_type, 'jobs', index_type, 'consumes', any_string, 'properties']
        ignored_subtrees
      end

      it 'should call interpolate with the correct arguments' do
        expect(subject).to receive(:interpolate).with({'name' => '{{placeholder}}'}, nil, {subtrees_to_ignore: ignored_subtrees, must_be_absolute_name: true}).and_return({'name' => 'smurf'})
        result = subject.interpolate_runtime_manifest({'name' => '{{placeholder}}'})
        expect(result).to eq({'name' => 'smurf'})
      end
    end

    describe '#prepare_and_get_property' do
      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }
      let(:ok_response) do
        response = SampleSuccessResponse.new
        response.body = {
          :data => [
            :id => 'whateverid',
            :name => 'whatevername',
            :value => 'hello',
          ]
        }.to_json
        response
      end

      context 'when property value provided is nil' do
        it 'returns default value' do
          expect(client.prepare_and_get_property(nil, 'my_default_value', 'some_type', deployment_name)).to eq('my_default_value')
        end
      end

      context 'when property value is NOT nil' do
        context 'when property value is NOT a full placeholder (NOT padded with brackets)' do
          it 'returns that property value' do
            expect(client.prepare_and_get_property('my_smurf', 'my_default_value', nil, deployment_name)).to eq('my_smurf')
            expect(client.prepare_and_get_property('((my_smurf', 'my_default_value', nil, deployment_name)).to eq('((my_smurf')
            expect(client.prepare_and_get_property('my_smurf))', 'my_default_value', 'whatever', deployment_name)).to eq('my_smurf))')
            expect(client.prepare_and_get_property('((my_smurf))((vroom))', 'my_default_value', 'whatever', deployment_name)).to eq('((my_smurf))((vroom))')
            expect(client.prepare_and_get_property('((my_smurf)) i am happy', 'my_default_value', 'whatever', deployment_name)).to eq('((my_smurf)) i am happy')
            expect(client.prepare_and_get_property('this is ((smurf_1)) this is ((smurf_2))', 'my_default_value', 'whatever', deployment_name)).to eq('this is ((smurf_1)) this is ((smurf_2))')
          end
        end

        context 'when property value is a FULL placeholder (padded with brackets)' do
          context 'when placeholder syntax is invalid' do
            it 'raises an error' do
              expect{
                client.prepare_and_get_property('((invalid name $%$^))', 'my_default_value', nil, deployment_name)
              }. to raise_error(Bosh::Director::ConfigServerIncorrectNameSyntax)
            end
          end

          context 'when placeholder syntax is valid' do
            let(:the_placeholder) { '((my_smurf))' }
            let(:bang_placeholder) { '((!my_smurf))' }

            context 'when config server returns an error while checking for name' do
              it 'raises an error' do
                expect(http_client).to receive(:get).with(prepend_namespace('my_smurf')).and_return(SampleForbiddenResponse.new)
                expect{
                  client.prepare_and_get_property(the_placeholder, 'my_default_value', nil, deployment_name)
                }. to raise_error(Bosh::Director::ConfigServerFetchError, "Failed to fetch variable '/smurf_director_name/deployment_name/my_smurf' from config server: HTTP code '403'")
              end
            end

            context 'when value is found in config server' do
              it 'returns that property value as is' do
                expect(http_client).to receive(:get).with(prepend_namespace('my_smurf')).and_return(ok_response)
                expect(client.prepare_and_get_property(the_placeholder, 'my_default_value', nil, deployment_name)).to eq(the_placeholder)
              end

              it 'returns that property value as is when it starts with exclamation mark' do
                expect(http_client).to receive(:get).with(prepend_namespace('my_smurf')).and_return(ok_response)
                expect(client.prepare_and_get_property(bang_placeholder, 'my_default_value', nil, deployment_name)).to eq(bang_placeholder)
              end
            end

            context 'when value is NOT found in config server' do
              before do
                expect(http_client).to receive(:get).with(prepend_namespace('my_smurf')).and_return(SampleNotFoundResponse.new)
              end

              context 'when default is defined' do
                it 'returns the default value when type is nil' do
                  expect(client.prepare_and_get_property(the_placeholder, 'my_default_value', nil, deployment_name)).to eq('my_default_value')
                end

                it 'returns the default value when type is defined' do
                  expect(client.prepare_and_get_property(the_placeholder, 'my_default_value', 'some_type', deployment_name)).to eq('my_default_value')
                end

                it 'returns the default value when type is defined and generatable' do
                  expect(client.prepare_and_get_property(the_placeholder, 'my_default_value', 'password', deployment_name)).to eq('my_default_value')
                end

                context 'when placeholder starts with exclamation mark' do
                  it 'returns the default value when type is nil' do
                    expect(client.prepare_and_get_property(bang_placeholder, 'my_default_value', nil, deployment_name)).to eq('my_default_value')
                  end

                  it 'returns the default value when type is defined' do
                    expect(client.prepare_and_get_property(bang_placeholder, 'my_default_value', 'some_type', deployment_name)).to eq('my_default_value')
                  end

                  it 'returns the default value when type is defined and generatable' do
                    expect(client.prepare_and_get_property(bang_placeholder, 'my_default_value', 'password', deployment_name)).to eq('my_default_value')
                  end
                end
              end

              context 'when default is NOT defined i.e nil' do
                let(:full_key) { prepend_namespace('my_smurf') }
                let(:default_value) { nil }
                let(:type){'any-type-you-like'}

                context 'when the release spec property defines a type' do
                  it 'generates the value and returns the user provided placeholder' do
                    expect(http_client).to receive(:post).with({'name' => "#{full_key}", 'type' => 'any-type-you-like', 'parameters' => {}}).and_return(SampleSuccessResponse.new)
                    expect(client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name)).to eq(the_placeholder)
                  end

                  it 'throws an error if generation errors' do
                    expect(http_client).to receive(:post).with({'name' => "#{full_key}", 'type' => 'any-type-you-like', 'parameters' => {}}).and_return(SampleForbiddenResponse.new)
                    expect(logger).to receive(:error)

                    expect{
                      client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name)
                    }. to raise_error(
                      Bosh::Director::ConfigServerGenerationError,
                      "Config Server failed to generate value for '#{full_key}' with type 'any-type-you-like'. Error: 'There was a problem.'"
                    )
                  end

                  context 'when placeholder starts with exclamation mark' do
                    it 'generates the value and returns the user provided placeholder' do
                      expect(http_client).to receive(:post).with({'name' => "#{full_key}", 'type' => 'any-type-you-like', 'parameters' => {}}).and_return(SampleSuccessResponse.new)
                      expect(client.prepare_and_get_property(bang_placeholder, default_value, type, deployment_name)).to eq(bang_placeholder)
                    end
                  end

                  context 'when type is certificate' do
                    let(:full_key) {prepend_namespace('my_smurf')}
                    let(:type){'certificate'}
                    let(:dns_record_names) do
                      %w(*.fake-name1.network-a.simple.bosh *.fake-name1.network-b.simple.bosh)
                    end

                    let(:options) do
                      {
                        :dns_record_names => dns_record_names
                      }
                    end

                    let(:post_body) do
                      {
                        'name' => full_key,
                        'type' => 'certificate',
                        'parameters' => {
                          'common_name' => dns_record_names[0],
                          'alternative_names' => dns_record_names
                        }
                      }
                    end

                    it 'generates a certificate and returns the user provided placeholder' do
                      expect(http_client).to receive(:post).with(post_body).and_return(SampleSuccessResponse.new)
                      expect(client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name, options)).to eq(the_placeholder)
                    end

                    it 'generates a certificate and returns the user provided placeholder even with dots' do
                      dotted_placeholder = '((my_smurf.ca))'
                      expect(http_client).to receive(:post).with(post_body).and_return(SampleSuccessResponse.new)
                      expect(client.prepare_and_get_property(dotted_placeholder, default_value, type, deployment_name, options)).to eq(dotted_placeholder)
                    end

                    it 'generates a certificate and returns the user provided placeholder even if nested' do
                      dotted_placeholder = '((my_smurf.ca.fingerprint))'
                      expect(http_client).to receive(:post).with(post_body).and_return(SampleSuccessResponse.new)
                      expect(client.prepare_and_get_property(dotted_placeholder, default_value, type, deployment_name, options)).to eq(dotted_placeholder)
                    end

                    it 'throws an error if generation of certficate errors' do
                      expect(http_client).to receive(:post).with(post_body).and_return(SampleForbiddenResponse.new)
                      expect(logger).to receive(:error)

                      expect{
                        client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name, options)
                      }. to raise_error(
                        Bosh::Director::ConfigServerGenerationError,
                        "Config Server failed to generate value for '#{full_key}' with type 'certificate'. Error: 'There was a problem.'"
                      )
                    end

                    context 'when placeholder starts with exclamation mark' do
                      it 'generates a certificate and returns the user provided placeholder' do
                        expect(http_client).to receive(:post).with(post_body).and_return(SampleSuccessResponse.new)
                        expect(client.prepare_and_get_property(bang_placeholder, default_value, type, deployment_name, options)).to eq(bang_placeholder)
                      end
                    end
                  end
                end

                context 'when the release spec property does NOT define a type' do
                  let(:type){ nil }
                  it 'returns that the user provided value as is' do
                    expect(client.prepare_and_get_property(the_placeholder, default_value, type, deployment_name)).to eq(the_placeholder)
                  end
                end
              end
            end
          end
        end
      end
    end

    describe '#generate_values' do
      let(:http_client) { double('Bosh::Director::ConfigServer::HTTPClient') }

      context 'when given a variables object' do

        context 'when some variable names syntax is NOT correct' do
          let(:variable_specs_list) do
            [
              [{'name' => 'p*laceholder_a', 'type' => 'password'}],
              [{'name' => 'placeholder_a/', 'type' => 'password'}],
              [{'name' => '', 'type' => 'password'}],
              [{'name' => ' ', 'type' => 'password'}],
              [{'name' => '((vroom))', 'type' => 'password'}],
            ]
          end

          it 'should throw an error and log it' do
            variable_specs_list.each do |variables_spec|
              expect{
                client.generate_values(Bosh::Director::DeploymentPlan::Variables.new(variables_spec), deployment_name)
              }.to raise_error Bosh::Director::ConfigServerIncorrectNameSyntax
            end
          end

        end

        context 'when some variable names is correct' do
          let(:variables_spec) do
            [
              {'name' => 'placeholder_a', 'type' => 'password'},
              {'name' => 'placeholder_b', 'type' => 'certificate', 'options' => {'common_name' => 'bosh.io', 'alternative_names' => ['a.bosh.io','b.bosh.io']}},
              {'name' => '/placeholder_c', 'type' => 'gold', 'options' => { 'need' => 'luck' }}
            ]
          end

          let(:variables_obj) do
            Bosh::Director::DeploymentPlan::Variables.new(variables_spec)
          end

          it 'should generate all the variables in order' do
            expect(http_client).to receive(:post).with(
              {
                'name' => prepend_namespace('placeholder_a'),
                'type' => 'password',
                'parameters' => {}
              }
            ).ordered.and_return(SampleSuccessResponse.new)

            expect(http_client).to receive(:post).with(
              {
                'name' => prepend_namespace('placeholder_b'),
                'type' => 'certificate',
                'parameters' => {'common_name' => 'bosh.io', 'alternative_names' => %w(a.bosh.io b.bosh.io)}
              }
            ).ordered.and_return(SampleSuccessResponse.new)

            expect(http_client).to receive(:post).with(
              {
                'name' => '/placeholder_c',
                'type' => 'gold',
                'parameters' => { 'need' => 'luck' }
              }
            ).ordered.and_return(SampleSuccessResponse.new)

            client.generate_values(variables_obj, deployment_name)
          end

          context 'when config server throws an error while generating' do
            before do
              allow(http_client).to receive(:post).with(
                {
                  'name' => prepend_namespace('placeholder_a'),
                  'type' => 'password',
                  'parameters' => {}
                }
              ).ordered.and_return(SampleForbiddenResponse.new)
            end

            it 'should throw an error and log it' do
              expect(logger).to receive(:error)

              expect{
                client.generate_values(variables_obj, deployment_name)
              }.to raise_error(
                     Bosh::Director::ConfigServerGenerationError,
                     "Config Server failed to generate value for '/smurf_director_name/deployment_name/placeholder_a' with type 'password'. Error: 'There was a problem.'"
                   )
            end
          end
        end
      end
    end

    def generate_success_response(body)
      result = SampleSuccessResponse.new
      result.body = body
      result
    end
  end

  describe DisabledClient do

    subject(:disabled_client) { DisabledClient.new }
    let(:deployment_name) { 'smurf_deployment' }

    describe '#interpolate' do
      let(:src) do
        {
          'test' => 'smurf',
          'test2' => '((placeholder))'
        }
      end

      it 'returns src as is' do
        expect(disabled_client.interpolate(src, deployment_name)).to eq(src)
      end
    end

    describe '#interpolate_deployment_manifest' do
      let(:manifest) do
        {
          'test' => 'smurf',
          'test2' => '((placeholder))'
        }
      end

      it 'returns manifest as is' do
        expect(disabled_client.interpolate_deployment_manifest(manifest)).to eq(manifest)
      end
    end

    describe '#interpolate_runtime_manifest' do
      let(:manifest) do
        {
          'test' => 'smurf',
          'test2' => '((placeholder))'
        }
      end

      it 'returns manifest as is' do
        expect(disabled_client.interpolate_runtime_manifest(manifest)).to eq(manifest)
      end
    end

    describe '#prepare_and_get_property' do
      it 'returns manifest property value if defined' do
        expect(disabled_client.prepare_and_get_property('provided prop', 'default value is here', nil, deployment_name)).to eq('provided prop')
        expect(disabled_client.prepare_and_get_property('provided prop', 'default value is here', nil, deployment_name, {})).to eq('provided prop')
        expect(disabled_client.prepare_and_get_property('provided prop', 'default value is here', nil, deployment_name, {'whatever' => 'hello'})).to eq('provided prop')
      end
      it 'returns default value when manifest value is nil' do
        expect(disabled_client.prepare_and_get_property(nil, 'default value is here', nil, deployment_name)).to eq('default value is here')
        expect(disabled_client.prepare_and_get_property(nil, 'default value is here', nil, deployment_name, {})).to eq('default value is here')
        expect(disabled_client.prepare_and_get_property(nil, 'default value is here', nil, deployment_name, {'whatever' => 'hello'})).to eq('default value is here')
      end
    end

    describe '#generate_values' do
      it 'exists' do
        expect{disabled_client.generate_values(anything, anything)}.to_not raise_error
      end
    end
  end

  class SampleSuccessResponse < Net::HTTPOK
    attr_accessor :body

    def initialize
      super(nil, '200', nil)
    end
  end

  class SampleNotFoundResponse < Net::HTTPNotFound
    def initialize
      super(nil, '404', 'Not Found Brah')
    end
  end

  class SampleForbiddenResponse < Net::HTTPForbidden
    def initialize
      super(nil, '403', 'There was a problem.')
    end
  end
  end
