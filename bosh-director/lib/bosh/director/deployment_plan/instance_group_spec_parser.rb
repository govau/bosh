require 'bosh/template/property_helper'

module Bosh::Director
  module DeploymentPlan
    class InstanceGroupSpecParser
      include ValidationHelper
      include Bosh::Template::PropertyHelper
      include IpUtil

      # @param [Bosh::Director::DeploymentPlan] deployment Deployment plan
      def initialize(deployment, event_log, logger)
        @deployment = deployment
        @event_log = event_log
        @logger = logger
      end

      # @param [Hash] instance_group_spec Raw instance_group spec from the deployment manifest
      # @return [DeploymentPlan::InstanceGroup] Instance groups as built from instance_group_spec
      def parse(instance_group_spec, options = {})
        @instance_group_spec = instance_group_spec
        @instance_group = InstanceGroup.new(@logger)

        parse_name
        parse_lifecycle

        parse_release
        validate_jobs

        parse_legacy_template
        parse_jobs

        check_job_uniqueness
        parse_disk
        parse_properties
        parse_resource_pool
        check_remove_dev_tools

        parse_options = {}
        parse_options['canaries'] = options['canaries'] if options['canaries']
        parse_options['max_in_flight'] = options['max_in_flight'] if options['max_in_flight']
        parse_update_config(parse_options)

        networks = InstanceGroupNetworksParser.new(Network::VALID_DEFAULTS).parse(@instance_group_spec, @instance_group.name, @deployment.networks)
        @instance_group.networks = networks
        assign_default_networks(networks)

        availability_zones = InstanceGroupAvailabilityZoneParser.new.parse(@instance_group_spec, @instance_group, @deployment, networks)
        @instance_group.availability_zones = availability_zones

        parse_migrated_from

        desired_instances = parse_desired_instances(availability_zones, networks)
        @instance_group.desired_instances = desired_instances

        @instance_group
      end

      private

      def parse_name
        @instance_group.name = safe_property(@instance_group_spec, "name", :class => String)
        @instance_group.canonical_name = Canonicalizer.canonicalize(@instance_group.name)
      end

      def parse_lifecycle
        lifecycle = safe_property(@instance_group_spec, "lifecycle",
          :class => String,
          :optional => true,
          :default => InstanceGroup::DEFAULT_LIFECYCLE_PROFILE,
        )

        unless InstanceGroup::VALID_LIFECYCLE_PROFILES.include?(lifecycle)
          raise JobInvalidLifecycle,
            "Invalid lifecycle '#{lifecycle}' for '#{@instance_group.name}', " +
            "valid lifecycle profiles are: #{InstanceGroup::VALID_LIFECYCLE_PROFILES.join(', ')}"
        end

        @instance_group.lifecycle = lifecycle
      end

      def parse_release
        release_name = safe_property(@instance_group_spec, "release", :class => String, :optional => true)

        if release_name.nil?
          if @deployment.releases.size == 1
            @instance_group.release = @deployment.releases.first
          end
        else
          @instance_group.release = @deployment.release(release_name)

          if @instance_group.release.nil?
            raise InstanceGroupUnknownRelease,
                  "Instance group '#{@instance_group.name}' references an unknown release '#{release_name}'"
          end
        end
      end

      # legacy template parsing
      def parse_legacy_template
        template_names = safe_property(@instance_group_spec, "template", optional: true)
        if template_names
          if template_names.is_a?(Array)
            @event_log.warn_deprecated(
              "Please use 'templates' when specifying multiple templates for a job. " +
              "'template' for multiple templates will soon be unsupported."
            )
          end

          unless template_names.is_a?(Array) || template_names.is_a?(String)
            invalid_type("template", "String or Array", template_names)
          end

          unless @instance_group.release
            raise InstanceGroupMissingRelease, "Cannot tell what release job '#{@instance_group.name}' is supposed to use, please explicitly specify one"
          end

          Array(template_names).each do |template_name|
            @instance_group.templates << @instance_group.release.get_or_create_template(template_name)
          end
        end
      end

      def parse_jobs
        legacy_jobs = safe_property(@instance_group_spec, 'templates', class: Array, optional: true)
        jobs = safe_property(@instance_group_spec, 'jobs', class: Array, optional: true)

        if jobs.nil?
          jobs = legacy_jobs
        end

        if jobs
          release_manager = Api::ReleaseManager.new

          # Key: release name.
          # Value: list of templates models of release version.
          release_versions_templates_models_hash = {}

          jobs.each do |job_spec|
            template_name = safe_property(job_spec, 'name', class: String)
            release_name = safe_property(job_spec, 'release', class: String, optional: true)

            if release_name
              release = @deployment.release(release_name)
              unless release
                raise InstanceGroupUnknownRelease,
                      "Job '#{template_name}' (instance group '#{@instance_group.name}') references an unknown release '#{release_name}'"
              end
            else
              release = @instance_group.release
              unless release
                raise InstanceGroupMissingRelease, "Cannot tell what release template '#{template_name}' (instance group '#{@instance_group.name}') is supposed to use, please explicitly specify one"
              end
            end

            if !release_versions_templates_models_hash.has_key?(release_name)
              release_model = release_manager.find_by_name(release.name)
              current_release_version = release_manager.find_version(release_model, release.version)
              release_versions_templates_models_hash[release_name] = current_release_version.templates
            end

            templates_models_list = release_versions_templates_models_hash[release_name]
            current_template_model = templates_models_list.find {|target| target.name == template_name }

            template = release.get_or_create_template(template_name)

            if current_template_model == nil
              raise "Job '#{template_name}' not found in Template table"
            end

            if current_template_model.consumes != nil
              current_template_model.consumes.each do |consumes|
                template.add_link_from_release(@instance_group.name,'consumes', consumes["name"], consumes)
              end
            end
            if current_template_model.provides != nil
              current_template_model.provides.each do |provides|
                template.add_link_from_release(@instance_group.name, 'provides', provides["name"], provides)
              end
            end

            provides_links = safe_property(job_spec, 'provides', class: Hash, optional: true)
            provides_links.to_a.each do |link_name, source|
              template.add_link_from_manifest(@instance_group.name, "provides", link_name, source)
            end

            consumes_links = safe_property(job_spec, 'consumes', class: Hash, optional: true)
            consumes_links.to_a.each do |link_name, source|
              template.add_link_from_manifest(@instance_group.name, 'consumes', link_name, source)
            end

            if job_spec.has_key?("properties")
              template.add_template_scoped_properties(
                  safe_property(job_spec, 'properties', class: Hash, optional: true, default: nil),
                  @instance_group.name
              )

              template.add_template_scoped_uninterpolated_properties(
                  safe_property(job_spec, 'uninterpolated_properties', class: Hash, optional: true, default: nil),
                  @instance_group.name
              )
            end

            @instance_group.templates << template
          end
        end
      end

      def check_job_uniqueness
        all_names = @instance_group.templates.map(&:name)
        @instance_group.templates.each do |template|
          if all_names.count(template.name) > 1
            raise InstanceGroupInvalidTemplates,
                  "Colocated job '#{template.name}' is already added to the instance group '#{@instance_group.name}'"
          end
        end
      end

      def parse_disk
        disk_size = safe_property(@instance_group_spec, 'persistent_disk', :class => Integer, :optional => true)
        disk_type_name = safe_property(@instance_group_spec, 'persistent_disk_type', :class => String, :optional => true)
        disk_pool_name = safe_property(@instance_group_spec, 'persistent_disk_pool', :class => String, :optional => true)

        if disk_type_name && disk_pool_name
          raise InstanceGroupInvalidPersistentDisk,
            "Instance group '#{@instance_group.name}' specifies both 'disk_types' and 'disk_pools', only one key is allowed. " +
              "'disk_pools' key will be DEPRECATED in the future."
        end

        if disk_type_name
          disk_name = disk_type_name
          disk_source = 'type'
        else
          disk_name = disk_pool_name
          disk_source = 'pool'
        end

        if disk_size && disk_name
          raise InstanceGroupInvalidPersistentDisk,
            "Instance group '#{@instance_group.name}' references both a persistent disk size '#{disk_size}' " +
              "and a persistent disk #{disk_source} '#{disk_name}'"
        end

        if disk_size
          if disk_size < 0
            raise InstanceGroupInvalidPersistentDisk,
              "Instance group '#{@instance_group.name}' references an invalid persistent disk size '#{disk_size}'"
          else
            @instance_group.persistent_disk = disk_size
          end
        end

        if disk_name
          disk_type = @deployment.disk_type(disk_name)
          if disk_type.nil?
            raise InstanceGroupUnknownDiskType,
                  "Instance group '#{@instance_group.name}' references an unknown disk #{disk_source} '#{disk_name}'"
          else
            @instance_group.persistent_disk_type = disk_type
          end
        end
      end

      def parse_properties
        # Manifest can contain global and per-job properties section
        job_properties = safe_property(@instance_group_spec, "properties", :class => Hash, :optional => true, :default => {})
        uninterpolated_job_properties = safe_property(@instance_group_spec, "uninterpolated_properties", :class => Hash, :optional => true, :default => {})

        @instance_group.all_properties = @deployment.properties.recursive_merge(job_properties)
        @instance_group.all_uninterpolated_properties = @deployment.uninterpolated_properties.recursive_merge(uninterpolated_job_properties)

        mappings = safe_property(@instance_group_spec, "property_mappings", :class => Hash, :default => {})

        mappings.each_pair do |to, from|
          resolved = lookup_property(@instance_group.all_properties, from)

          if resolved.nil?
            raise InstanceGroupInvalidPropertyMapping,
                  "Cannot satisfy property mapping '#{to}: #{from}', as '#{from}' is not in deployment properties"
          end

          @instance_group.all_properties[to] = resolved
        end
      end

      def parse_resource_pool
        env_hash = safe_property(@instance_group_spec, 'env', class: Hash, :default => {})
        uninterpolated_env_hash = safe_property(@instance_group_spec, 'uninterpolated_env', class: Hash, :default => {})

        resource_pool_name = safe_property(@instance_group_spec, "resource_pool", class: String, optional: true)

        if resource_pool_name
          resource_pool = @deployment.resource_pool(resource_pool_name)
          if resource_pool.nil?
            raise InstanceGroupUnknownResourcePool,
              "Instance group '#{@instance_group.name}' references an unknown resource pool '#{resource_pool_name}'"
          end

          vm_type = VmType.new({
            'name' => resource_pool.name,
            'cloud_properties' => resource_pool.cloud_properties
          })

          vm_extensions = []

          stemcell = resource_pool.stemcell

          if !env_hash.empty? && !resource_pool.env.empty?
            raise InstanceGroupAmbiguousEnv,
              "Instance group '#{@instance_group.name}' and resource pool: '#{resource_pool_name}' both declare env properties"
          end

          if env_hash.empty?
            env_hash = resource_pool.env
          end
        else
          vm_type_name = safe_property(@instance_group_spec, 'vm_type', class: String)
          vm_type = @deployment.vm_type(vm_type_name)
          if vm_type.nil?
            raise InstanceGroupUnknownVmType,
              "Instance group '#{@instance_group.name}' references an unknown vm type '#{vm_type_name}'"
          end

          vm_extension_names = Array(safe_property(@instance_group_spec, 'vm_extensions', class: Array, optional: true))
          vm_extensions = Array(vm_extension_names).map {|vm_extension_name| @deployment.vm_extension(vm_extension_name)}

          stemcell_name = safe_property(@instance_group_spec, 'stemcell', class: String)
          stemcell = @deployment.stemcell(stemcell_name)
          if stemcell.nil?
            raise InstanceGroupUnknownStemcell,
              "Instance group '#{@instance_group.name}' references an unknown stemcell '#{stemcell_name}'"
          end
        end

        @instance_group.vm_type = vm_type
        @instance_group.vm_extensions = vm_extensions
        @instance_group.stemcell = stemcell
        @instance_group.env = Env.new(env_hash, uninterpolated_env_hash)
      end

      def parse_update_config(parse_options)
        update_spec = safe_property(@instance_group_spec, "update", class: Hash, optional: true)
        @instance_group.update = UpdateConfig.new((update_spec || {}).merge(parse_options), @deployment.update)
      end

      def parse_desired_instances(availability_zones, networks)
        @instance_group.state = safe_property(@instance_group_spec, "state", class: String, optional: true)
        instances = safe_property(@instance_group_spec, "instances", class: Integer)
        instance_states = safe_property(@instance_group_spec, "instance_states", class: Hash, default: {})

        networks.each do |network|
          static_ips = network.static_ips
          if static_ips && static_ips.size != instances
            raise InstanceGroupNetworkInstanceIpMismatch,
              "Instance group '#{@instance_group.name}' has #{instances} instances but was allocated #{static_ips.size} static IPs in network '#{network.name}'"
          end
        end

        instance_states.each_pair do |index_or_id, state|
          unless InstanceGroup::VALID_STATES.include?(state)
            raise InstanceGroupInvalidInstanceState,
              "Invalid state '#{state}' for '#{@instance_group.name}/#{index_or_id}', valid states are: #{InstanceGroup::VALID_STATES.join(", ")}"
          end

          @instance_group.instance_states[index_or_id] = state
        end

        if @instance_group.state && !InstanceGroup::VALID_STATES.include?(@instance_group.state)
          raise InstanceGroupInvalidState,
            "Invalid state '#{@instance_group.state}' for '#{@instance_group.name}', valid states are: #{InstanceGroup::VALID_STATES.join(", ")}"
        end

        instances.times.map { DesiredInstance.new(@instance_group, @deployment) }
      end

      def parse_migrated_from
        migrated_from = safe_property(@instance_group_spec, 'migrated_from', class: Array, optional: true, :default => [])
        migrated_from.each do |migrated_from_job_spec|
          name = safe_property(migrated_from_job_spec, 'name', class: String)
          az = safe_property(migrated_from_job_spec, 'az', class: String, optional: true)
          unless az.nil?
            unless @instance_group.availability_zones.to_a.map(&:name).include?(az)
              raise DeploymentInvalidMigratedFromJob,
              "Instance group '#{name}' specified for migration to instance group '#{@instance_group.name}' refers to availability zone '#{az}'. " +
                "Az '#{az}' is not in the list of availability zones of instance group '#{@instance_group.name}'."
            end
          end
          @instance_group.migrated_from << MigratedFromJob.new(name, az)
        end
      end

      def validate_jobs
        template_property = safe_property(@instance_group_spec, 'template', optional: true)
        templates_property = safe_property(@instance_group_spec, 'templates', optional: true)
        jobs_property = safe_property(@instance_group_spec, 'jobs', optional: true)

        if template_property && templates_property
          raise InstanceGroupInvalidTemplates, "Instance group '#{@instance_group.name}' specifies both template and templates keys, only one is allowed"
        end

        if templates_property && jobs_property
          raise InstanceGroupInvalidTemplates, "Instance group '#{@instance_group.name}' specifies both templates and jobs keys, only one is allowed"
        end

        if template_property && jobs_property
          raise InstanceGroupInvalidTemplates, "Instance group '#{@instance_group.name}' specifies both template and jobs keys, only one is allowed"
        end

        if [template_property, templates_property, jobs_property].compact.empty?
          raise ValidationMissingField,
                "Instance group '#{@instance_group.name}' does not specify template, templates, or jobs keys, one is required"
        end
      end

      def assign_default_networks(networks)
        Network::VALID_DEFAULTS.each do |property|
          network = networks.find { |network| network.default_for?(property) }
          @instance_group.default_network[property] = network.name if network
        end
      end

      def check_remove_dev_tools
        if Config.remove_dev_tools
          @instance_group.env.spec['bosh'] ||= {}
          unless @instance_group.env.spec['bosh'].has_key?('remove_dev_tools')
            @instance_group.env.spec['bosh']['remove_dev_tools'] = Config.remove_dev_tools
          end
        end
      end
    end
  end
end
