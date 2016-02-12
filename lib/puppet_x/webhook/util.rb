require 'puppetclassify' if Puppet.features.puppetclassify?
require 'puppet/network/http_pool'
require 'puppet/application/apply'

module PuppetX
  module Webhook
    module Util

      # return current r10k config
      def self.load_r10k_yaml(yaml_path)
        # Load the existing r10k yaml file, if it exists
        if File.exist?(yaml_path)
          r10k_yaml = YAML.load_file(yaml_path)
        else
          raise "Unable to file r10k.yaml at path #{yaml_path}, use --r10k_yaml for custom location"
        end
        # Not checking private key here as technically it optional
        unless r10k_yaml.has_key?('git') && r10k_yaml['git']['provider'] == 'rugged'
          Puppet.err "Specified #{yaml_path} is not using rugged provider, you must migrate to rugged before using code manager"
          raise "Missing key ['git']['provider']['rugged'] in r10k.yaml see: https://github.com/puppetlabs/r10k/blob/master/doc/git/providers.mkd"
        end
        r10k_yaml
      rescue Exception => e
        raise "Unable to load r10k.yaml file: #{e.message}"
      end

      # Read classifier.yaml for split installation compatibility
      def self.load_classifier_config
        configfile = File.join Puppet.settings[:confdir], 'classifier.yaml'
        if File.exist?(configfile)
          classifier_yaml = YAML.load_file(configfile)
          @classifier_url = "https://#{classifier_yaml['server']}:#{classifier_yaml['port']}/classifier-api"
        else
          Puppet.debug "Config file #{configfile} not found"
          raise "no classifier config file! - wanted #{configfile}"
        end
      end

      # Create classifier instance var
      # Uses the local hostcertificate for auth ( assume we are
      # running from master in whitelist entry of classifier ).
      def self.load_classifier()
        auth_info = {
          'ca_certificate_path' => Puppet[:localcacert],
          'certificate_path'    => Puppet[:hostcert],
          'private_key_path'    => Puppet[:hostprivkey],
        }
        unless @classifier
          load_classifier_config
          @classifier = PuppetClassify.new(@classifier_url, auth_info)
        end
      end

      def self.http_instance(host,port,whitelist: true)
        if whitelist
          Puppet::Network::HttpPool.http_instance(host,port,true)
        else
          http = Net::HTTP.new(host,port)
          http.use_ssl = ssl
          http.cert = OpenSSL::X509::Certificate.new(File.read(Puppet[:hostcert]))
          http.key = OpenSSL::PKey::RSA.new(File.read(Puppet[:hostprivkey]))
          http.ca_file = Puppet[:localcacert]
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http
        end
      end

      def self.update_master_profile(r10k_private_key: '/etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa',r10k_remote: '')
        Puppet.notice("Adding code manager params to master profile in classifier")
        load_classifier
        groups = @classifier.groups
        pe_master = groups.get_groups.select { |group| group['name'] == 'PE Master'}
      
        classes = pe_master.first['classes']
      
        master_profile = classes['puppet_enterprise::profile::master']
        master_profile.update(master_profile.merge(
          'r10k_private_key'             => r10k_private_key,
          'r10k_remote'                  => r10k_remote, 
          'file_sync_enabled'            => true,
           'code_manager_auto_configure' => true,
        ))
      
        group_hash = pe_master.first.merge({ "classes" => {"puppet_enterprise::profile::master" => master_profile}})
      
        groups.update_group(group_hash)
      end

      def self.run_puppet(argv)
        command_line = Puppet::Util::CommandLine.new('puppet', argv)
        apply = Puppet::Application::Apply.new(command_line)
        apply.parse_options
        apply.run_command
      end

      def self.service(service,action)
        Puppet.notice "Attempting to ensure=>#{action} #{service}"
        start_service = Puppet::Resource.new('service',service, :parameters => {
          :ensure => action,
        })
        result, report = Puppet::Resource.indirection.save(start_service)
      end
 
      def self.service_restart(service)
        self.service(service,'stopped')
        self.service(service,'running')
      end
    end
  end
end
