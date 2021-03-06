require 'rspec'

namespace :fly do
  # bundle exec rake fly:unit
  desc 'Fly unit specs'
  task :unit do
    execute('test-unit', '-p',
            DB: (ENV['DB'] || 'postgresql'),
            DB_VERSION: (ENV['DB_VERSION'] || '10'))
  end

  # bundle exec rake fly:integration
  desc 'Fly integration gocli specs'
  task :integration do
    execute('test-integration-gocli', '-p --inputs-from bosh/integration-db-tls-postgres',
            DB: (ENV['DB'] || 'postgresql'), SPEC_PATH: (ENV['SPEC_PATH'] || nil))
  end

  # bundle exec rake fly:run["pwd ; ls -al"]
  task :run, [:command] do |_, args|
    execute('run', '-p',
            COMMAND: %(\"#{args[:command]}\"))
  end

  private

  def concourse_tag
    tag = ENV.fetch('CONCOURSE_TAG', 'fly-integration')
    "--tag=#{tag}" unless tag.empty?
  end

  def concourse_target
    "-t #{ENV['CONCOURSE_TARGET']}" if ENV.key?('CONCOURSE_TARGET')
  end

  def prepare_env(additional_env = {})
    env = {
      RUBY_VERSION: ENV['RUBY_VERSION'] || RUBY_VERSION,
    }
    env.merge!(additional_env)

    env.to_a.map { |pair| pair.join('=') }.join(' ')
  end

  def execute(task, command_options = nil, additional_env = {})
    env = prepare_env(additional_env)
    sh("#{env} fly #{concourse_target} sync")
    sh(
      "#{env} fly #{concourse_target} execute #{concourse_tag} #{command_options} -c ../ci/tasks/#{task}.yml -i bosh-src=$PWD/../",
    )
  end
end

desc 'Fly unit and integration specs'
task fly: %w[fly:unit fly:integration]
