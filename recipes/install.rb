require 'json'
require 'base64'
require 'digest'

domain_name="domain1"
domains_dir = node['hopsworks']['domains_dir']
theDomain="#{domains_dir}/#{domain_name}"
password_file = "#{theDomain}_admin_passwd"
namenode_fdqn = consul_helper.get_service_fqdn("rpc.namenode")
glassfish_fdqn = consul_helper.get_service_fqdn("glassfish")

private_ip=my_private_ip()
das_node_ip=node['hopsworks'].attribute?('das_node')? private_recipe_ip('hopsworks', 'das_node') : ""
systemd_enabled=das_node_ip.empty? || das_node_ip == private_ip

bash "systemd_reload_for_glassfish_failures" do
  user "root"
  ignore_failure true
  code <<-EOF
    systemctl daemon-reload
    systemctl stop glassfish-#{domain_name}
  EOF
  only_if { systemd_enabled }
end

# When we upgrade to version 3.1.0 make sure we have set the subjects
# of CAs
if conda_helpers.is_upgrade && Gem::Version.new(node['install']['current_version']) < Gem::Version.new('3.1.0')
  if node['hopsworks']['pki']['root']['name'].empty? || node['hopsworks']['pki']['intermediate']['name'].empty?
    raise "It is an upgrade and Hopsworks CA subject name are not set. You have to set it to what was the previous names"
  end

  # To support migration from Payara 4 to Payara 5 we need to re-generate the domain.
  # We can drop the existing domain, but we need to save some files from it
  bash 'Move old domains dir to domains4 for backup' do
    user 'root'
    code <<-EOH
      set -e
      mv -f #{node['hopsworks']['domains_dir']} #{node['hopsworks']['domains_dir']}4
    EOH
    not_if { File.exists?("#{node['hopsworks']['domains_dir']}4")}
    only_if { File.exists?("#{node['hopsworks']['domains_dir']}") }
  end
end

group node['hopsworks']['group'] do
  gid node['hopsworks']['group_id']
  action :create
  not_if "getent group #{node['hopsworks']['group']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

#
# hdfs superuser group is 'hdfs'
#
group node['hops']['hdfs']['group'] do
  gid node['hops']['hdfs']['group_id']
  action :create
  not_if "getent group #{node['hops']['hdfs']['group']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

user node['hopsworks']['user'] do
  home node['glassfish']['user-home']
  uid node['hopsworks']['user_id']
  gid node['hopsworks']['group']
  action :create
  shell "/bin/bash"
  manage_home true
  not_if "getent passwd #{node['hopsworks']['user']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

group node["kagent"]["certs_group"] do
  action :manage
  append true
  excluded_members node['hopsworks']['user']
  not_if { node['install']['external_users'].casecmp("true") == 0 }
  only_if { conda_helpers.is_upgrade }
end

# Add to the hdfs superuser group
group node['hops']['hdfs']['group'] do
  action :modify
  members ["#{node['hopsworks']['user']}"]
  append true
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

group node['hops']['group'] do
  gid node['hops']['group_id']
  action :create
  not_if "getent group #{node['hops']['group']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

group node['hops']['group'] do
  action :modify
  members ["#{node['hopsworks']['user']}"]
  append true
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

group node['hopsmonitor']['group'] do
  action :modify
  members ["#{node['hopsworks']['user']}"]
  append true
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

group node['airflow']['group'] do
  action :modify
  members ["#{node['hopsworks']['user']}"]  
  append true
  not_if { node['install']['external_users'].casecmp("true") == 0 }
  only_if "getent group #{node['airflow']['group']}"
end

group node['logger']['group'] do
  gid node['logger']['group_id']
  action :create
  not_if "getent group #{node['logger']['group']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

user node['logger']['user'] do
  uid node['logger']['user_id']
  gid node['logger']['group_id']
  shell "/bin/nologin"
  action :create
  system true
  not_if "getent passwd #{node['logger']['user']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

group node["hopsworks"]["group"] do
  action :modify
  members [node['logger']['user']]
  append true
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

#update permissions of base_dir to 770
directory node['jupyter']['base_dir']  do
  owner node['hops']['yarnapp']['user']
  group node['hops']['group']
  mode "770"
  action :create
end

directory node['hopsworks']['dir']  do
  owner node['hopsworks']['user']
  group node['hopsworks']['group']
  mode "755"
  action :create
  not_if "test -d #{node['hopsworks']['dir']}"
end

directory domains_dir  do
  owner node['hopsworks']['user']
  group node['hopsworks']['group']
  mode "750"
  action :create
  not_if "test -d #{domains_dir}"
end

# Install authbind to allow glassfish to bind on ports < 1024
# and Kerberos libraries for SSO
case node['platform_family']
when "debian"
  package ["libkrb5-dev", "authbind", "iproute2"] do
    retries 10
    retry_delay 30
  end
when "rhel"
  package ["krb5-libs", "iproute"] do
    retries 10
    retry_delay 30
  end

  authbind_rpm = ::File.basename(node['authbind']['download_url'])

  remote_file "#{Chef::Config['file_cache_path']}/#{authbind_rpm}" do
    user node['glassfish']['user']
    group node['glassfish']['group']
    source node['authbind']['download_url']
    mode 0755
    action :create
  end

  package 'authbind' do
    source "#{Chef::Config['file_cache_path']}/#{authbind_rpm}"
    retries 10
    retry_delay 30
  end
end

# Configure authbind ports
authbind_port "Authbind Glassfish Admin port" do
  port node['hopsworks']['admin']['port'].to_i
  user node['glassfish']['user']
  only_if {node['hopsworks']['admin']['port'].to_i < 1024}
end

authbind_port "Authbind Glassfish https port" do
  port node['hopsworks']['https']['port'].to_i
  user node['glassfish']['user']
  only_if {node['hopsworks']['https']['port'].to_i < 1024}
end

file "#{node['hopsworks']['env_var_file']}" do
  content '# Generated by Chef. Environment variable exported for glassfish-domain1'
  mode 0700
  owner node['glassfish']['user']
  group node['glassfish']['group']
end

node.override = {
  'java' => {
    'install_flavor' => node['java']['install_flavor'],
    'jdk_version' => node['java']['jdk_version']
  },
  'glassfish' => {
    'version' => node['glassfish']['version'],
    'domains_dir' => node['hopsworks']['domains_dir'],
    'domains' => {
      domain_name => {
        'config' => {
          'debug' => node['hopsworks']['debug'],    
          'systemd_enabled' => systemd_enabled,
          'systemd_start_timeout' => 900,
          'min_memory' => node['glassfish']['min_mem'],
          'max_memory' => node['glassfish']['max_mem'],
          'max_perm_size' => node['glassfish']['max_perm_size'],
          'max_stack_size' => node['glassfish']['max_stack_size'],
          'port' => 8080, #This is hardcoded as it's not used. Http listener is disabled in hopsworks::default.
          'https_port' => node['hopsworks']['https']['port'].to_i,
          'admin_port' => node['hopsworks']['admin']['port'].to_i,
          'username' => node['hopsworks']['admin']['user'],
          'password' => node['hopsworks']['admin']['password'],
          'master_password' => node['hopsworks']['master']['password'],
          'remote_access' => false,
          'secure' => false,
          'environment_file' => node['hopsworks']['env_var_file'],
          'jvm_options' => ["-DHADOOP_HOME=#{node['hops']['dir']}/hadoop", "-DHADOOP_CONF_DIR=#{node['hops']['dir']}/hadoop/etc/hadoop", '-Dcom.sun.enterprise.tools.admingui.NO_NETWORK=true']
        },
        'extra_libraries' => {
          'jdbcdriver' => {
            'type' => 'common',
            'url' => node['hopsworks']['mysql_connector_url']
          }
        },
        'threadpools' => {
          'thread-pool-1' => {
            'maxthreadpoolsize' => 200,
            'minthreadpoolsize' => 5,
            'idletimeout' => 900,
            'maxqueuesize' => 4096
          },
          'http-thread-pool' => {
            'maxthreadpoolsize' => 200,
            'minthreadpoolsize' => 5,
            'idletimeout' => 900,
            'maxqueuesize' => 4096
          },
          'admin-pool' => {
            'maxthreadpoolsize' => 40,
            'minthreadpoolsize' => 5,
            'maxqueuesize' => 256
          }
        },
        'managed_thread_factories' => {
          'concurrent/hopsThreadFactory' => {
            'threadpriority' => 10,
            'description' => 'Hopsworks Thread Factory'
          }
        },
        'managed_executor_services' => {
          'concurrent/hopsExecutorService' => {
            'threadpriority' => 10,
            'corepoolsize' => 50,
            'maximumpoolsize' => 400,
            'taskqueuecapacity' => 20000,
            'description' => 'Hopsworks Executor Service'
          },
          'concurrent/condaExecutorService' => {
              'threadpriority' => 9,
              'corepoolsize' => 30,
              'maximumpoolsize' => 400,
              'taskqueuecapacity' => 20000,
              'description' => 'Hopsworks Conda Executor Service'
          },
          'concurrent/jupyterExecutorService' => {
              'threadpriority' => node['hopsworks']['managed_executor_pools']['jupyter']['threadpriority'],
              'corepoolsize' => node['hopsworks']['managed_executor_pools']['jupyter']['corepoolsize'],
              'maximumpoolsize' => node['hopsworks']['managed_executor_pools']['jupyter']['maximumpoolsize'],
              'taskqueuecapacity' => node['hopsworks']['managed_executor_pools']['jupyter']['taskqueuecapacity'],
              'longrunningtasks' => true,
              'description' => 'Hopsworks Jupyter Executor Service'
          }
        },
        'managed_scheduled_executor_services' => {
          'concurrent/hopsScheduledExecutorService' => {
            'corepoolsize' => 10,
            'description' => 'Hopsworks Executor Service'
          },
          'concurrent/condaScheduledExecutorService' => {
              'corepoolsize' => 10,
              'description' => 'Hopsworks Conda Executor Service'
          }
        },
        'jdbc_connection_pools' => {
          'hopsworksPool' => {
            'config' => {
              'datasourceclassname' => 'com.mysql.cj.jdbc.MysqlDataSource',
              'restype' => 'javax.sql.DataSource',
              'isconnectvalidatereq' => 'true',
              'validationmethod' => 'auto-commit',
              'ping' => 'true',
              'description' => 'Hopsworks Connection Pool',
              'properties' => {
                'Url' => "jdbc:mysql://127.0.0.1:3306/",
                'User' => node['hopsworks']['mysql']['user'],
                'Password' => node['hopsworks']['mysql']['password'],
                'useSSL' => 'false',
                'allowPublicKeyRetrieval' => 'true'
              }
            },
            'resources' => {
              'jdbc/hopsworks' => {
                'description' => 'Resource for Hopsworks Pool',
              }
            }
          },
          'featureStorePool' => {
            'config' => {
              'datasourceclassname' => 'com.mysql.cj.jdbc.MysqlDataSource',
              'restype' => 'javax.sql.DataSource',
              'isconnectvalidatereq' => 'true',
              'validationmethod' => 'auto-commit',
              'ping' => 'true',
              'description' => 'FeatureStore Connection Pool',
              'properties' => {
                'Url' => node['featurestore']['hopsworks_url'],
                'User' => node['featurestore']['user'],
                'Password' => node['featurestore']['password'],
                'useSSL' => 'false',
                'allowPublicKeyRetrieval' => 'true'
              }
            },
            'resources' => {
              'jdbc/featurestore' => {
                'description' => 'Resource for Hopsworks Pool',
              }
            }
          },
          'airflowPool' => {
            'config' => {
              'datasourceclassname' => 'com.mysql.cj.jdbc.MysqlDataSource',
              'restype' => 'javax.sql.DataSource',
              'isconnectvalidatereq' => 'true',
              'validationmethod' => 'auto-commit',
              'ping' => 'true',
              'description' => 'Airflow Connection Pool',
              'properties' => {
                'Url' => "jdbc:mysql://127.0.0.1:3306/",
                'User' => node['airflow']['mysql_user'],
                'Password' => node['airflow']['mysql_password'],
                'useSSL' => 'false',
                'allowPublicKeyRetrieval' => 'true'
              }
            },
            'resources' => {
              'jdbc/airflow' => {
                'description' => 'Resource for Airflow Pool',
              }
            }
          },
          'ejbTimerPool' => {
            'config' => {
              'datasourceclassname' => 'com.mysql.cj.jdbc.MysqlDataSource',
              'restype' => 'javax.sql.DataSource',
              'isconnectvalidatereq' => 'true',
              'validationmethod' => 'auto-commit',
              'ping' => 'true',
              'description' => 'Hopsworks EJB Connection Pool',
              'properties' => {
                'Url' => "jdbc:mysql://127.0.0.1:3306/glassfish_timers",
                'User' => node['hopsworks']['mysql']['user'],
                'Password' => node['hopsworks']['mysql']['password'],
                'useSSL' => 'false',
                'allowPublicKeyRetrieval' => 'true'
              }
            },
            'resources' => {
              'jdbc/hopsworksTimers' => {
                'description' => 'Resource for Hopsworks EJB Timers Pool',
              }
            }
          }
        }
      }
    }
  }
}

unless exists_local("hops_airflow", "default")
  node.override["glassfish"]["domains"][domain_name]["jdbc_connection_pools"].delete("airflowPool")
end

include_recipe 'glassfish::default'

directory node['data']['dir'] do
  owner 'root'
  group 'root'
  mode '0775'
  action :create
  not_if { ::File.directory?(node['data']['dir']) }
end

directory node['hopsworks']['data_volume']['staging_dir']  do
  owner node['hopsworks']['user']
  group node['hopsworks']['group']
  mode "775"
  action :create
  recursive true
end

directory node['hopsworks']['data_volume']['staging_dir'] + "/private_dirs"  do
  owner node['hops']['yarnapp']['user']
  group node['hopsworks']['group']
  mode "0370"
  action :create
end

directory node['hopsworks']['data_volume']['staging_dir'] + "/serving"  do
  owner node['hopsworks']['user']
  group node['hopsworks']['group']
  mode "0730"
  action :create
end

directory node['hopsworks']['data_volume']['staging_dir'] + "/tensorboard"  do
  owner node['conda']['user']
  group node['hopsworks']['group']
  mode "0770"
  action :create
end

bash 'Move staging to data volume' do
  user 'root'
  code <<-EOH
    set -e
    mv -f #{node['hopsworks']['staging_dir']}/* #{node['hopsworks']['data_volume']['staging_dir']}
    rm -rf #{node['hopsworks']['staging_dir']}
  EOH
  only_if { conda_helpers.is_upgrade }
  only_if { File.directory?(node['hopsworks']['staging_dir'])}
  not_if { File.symlink?(node['hopsworks']['staging_dir'])}
end

link node['hopsworks']['staging_dir'] do
  owner node['hopsworks']['user']
  group node['hopsworks']['group']
  mode "0770"
  to node['hopsworks']['data_volume']['staging_dir']
end

directory node['hopsworks']['conda_cache'] do
  owner node['hopsworks']['user']
  group node['hopsworks']['group']
  mode "0700"
  action :create
end

directory node['hopsworks']['data_volume']['root_dir'] do
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode '0750'
  not_if { ::File.directory?(node['hopsworks']['data_volume']['root_dir'])}
end

directory node['hopsworks']['data_volume']['domain1'] do
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode '0750'
end

directory node['hopsworks']['data_volume']['domain1_logs'] do
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode '0750'
end

package ["openssl", "zip"] do
  retries 10
  retry_delay 30
end

# In Hopsworks 3.1 we updated glassfish from 4.x to 5.x. As the domains
# are not compatible, we move the old domains dir to domains4 and
# expect the recipe to create new domain. The issue is that the if
# statement is evaluated at compile time while the move happens at runtime
# so essentially the if statement is always evaluated to true during an
# upgrade, it doesn't matter if we later move the dir and we want a completely
# new domain.
# We also want to make the recipe idempotent. If it fails during an upgrade
# but the domain has been re-generated already, it should not be generated again.
# So a fancy if statement that checks if we are doing a 3.1 upgrade is not possible.
# We cannot wrap the if statement within lazy {} as it's not ruby.
# So here we are with some ruby dark magic stolen from StackOverflow.
# The code inside the block is evaluated/executed at runtime, so here we are evaluating
# only if the new domain exists already.
ruby_block 'Run glassfish attribute driven domain' do
  block do
    if !::File.directory?("#{theDomain}/lib")
      run_context.include_recipe 'glassfish::attribute_driven_domain'
    end
  end
end

# Domain and logs directory is created by glassfish cookbook.
# Small hack to symlink logs directory
# if upgrade and a new HA node is added this needs to run as if it is a new install
# So check if the logs dir is empty and delete even if it is upgrade.
directory node['hopsworks']['domain1']['logs'] do
  recursive true
  action :delete
  only_if { Dir.entries(node['hopsworks']['domain1']['logs']).select {|entry| !(entry =='.' || entry == '..' || entry == '.gitkeep') }.empty? || !conda_helpers.is_upgrade }
end

bash 'Move glassfish logs to data volume' do
  user 'root'
  code <<-EOH
    set -e
    mv -f #{node['hopsworks']['domain1']['logs']}/* #{node['hopsworks']['data_volume']['domain1_logs']}
    mv -f #{node['hopsworks']['domain1']['logs']} #{node['hopsworks']['data_volume']['domain1_logs']}_deprecated
  EOH
  only_if { conda_helpers.is_upgrade }
  only_if { File.directory?(node['hopsworks']['domain1']['logs'])}
  not_if { File.symlink?(node['hopsworks']['domain1']['logs'])}
end

link node['hopsworks']['domain1']['logs'] do
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode '0750'
  to node['hopsworks']['data_volume']['domain1_logs']
end

directory node['hopsworks']['audit_log_dir'] do
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode '0700'
  action :create
end


mysql_connector = File.basename(node['hopsworks']['mysql_connector_url'])

remote_file "#{theDomain}/lib/#{mysql_connector}"  do
  user node['glassfish']['user']
  group node['glassfish']['group']
  source node['hopsworks']['mysql_connector_url']
  mode 0755
  action :create_if_missing
end

remote_directory "#{theDomain}/templates" do
  source 'hopsworks_templates'
  owner node["glassfish"]["user"]
  group node["glassfish"]["group"]
  mode 0750
  files_owner node["glassfish"]["user"]
  files_group node["glassfish"]["group"]
  files_mode 0550
end

directory "/etc/systemd/system/glassfish-#{domain_name}.service.d" do
  owner "root"
  group "root"
  mode "755"
  action :create
end

template "#{node['glassfish']['domains_dir']}/#{node['hopsworks']['domain_name']}/bin/glassfish-health.sh" do
  source "consul/glassfish-health.sh.erb"
  owner node['hopsworks']['user']
  group node['hops']['group']
  mode 0750
end

template "/etc/systemd/system/glassfish-#{domain_name}.service.d/limits.conf" do
  source "limits.conf.erb"
  owner "root"
  mode 0774
  action :create
end

ulimit_domain node['hopsworks']['user'] do
  rule do
    item :memlock
    type :soft
    value "unlimited"
  end
  rule do
    item :memlock
    type :hard
    value "unlimited"
  end
end

kagent_config "glassfish-domain1" do 
  action :systemd_reload
end

directory node['certs']['data_volume']['dir'] do
  owner node['glassfish']['user']
  group node['kagent']['certs_group']
  mode "755"
  action :create
end

ca_dir = node['certs']['dir']

bash 'Move system users x.509 to data volume' do
  user 'root'
  code <<-EOH
    set -e
    mv -f #{ca_dir}/* #{node['certs']['data_volume']['dir']}
  EOH
  only_if { conda_helpers.is_upgrade }
  only_if { File.directory?(ca_dir)}
  not_if { File.symlink?(ca_dir)}
  not_if { Dir.empty?(ca_dir)}
end

bash 'Delete old users x.509 directory' do
  user 'root'
  code <<-EOH
    set -e
    rm -rf #{ca_dir}
  EOH
  only_if { conda_helpers.is_upgrade }
  only_if { File.directory?(ca_dir)}
  not_if { File.symlink?(ca_dir)}
end

link ca_dir do
  owner node['glassfish']['user']
  group node['kagent']['certs_group']
  to node['certs']['data_volume']['dir']
end

master_password_digest = Digest::SHA256.hexdigest node['hopsworks']['encryption_password']

file "#{ca_dir}/encryption_master_password" do
  content "#{master_password_digest}"
  mode "0700"
  owner node['glassfish']['user']
  group node['glassfish']['group']
end

directory "#{ca_dir}/transient" do
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode "700"
  action :create
end

kagent_sudoers "jupyter" do 
  user          node['glassfish']['user']
  group         "root"
  script_name   "jupyter.sh"
  template      "jupyter.sh.erb"
  run_as        "ALL" # run this as root - inside we change to different users 
  not_if       { node['install']['kubernetes'].casecmp("true") == 0 }
end

kagent_sudoers "convert-ipython-notebook" do 
  user          node['glassfish']['user']
  group         "root"
  script_name   "convert-ipython-notebook.sh"
  template      "convert-ipython-notebook.sh.erb"
  run_as        "ALL" # run this as root - inside we change to different users 
end

kagent_sudoers "tensorboard" do 
  user          node['glassfish']['user']
  group         "root"
  script_name   "tensorboard.sh"
  template      "tensorboard.sh.erb"
  run_as        "ALL" # run this as root - inside we change to different users 
end

kagent_sudoers "tfserving" do 
  user          node['glassfish']['user']
  group         "root"
  script_name   "tfserving.sh"
  template      "tfserving.sh.erb"
  run_as        "ALL" # run this as root - inside we change to different users 
  not_if       { node['install']['kubernetes'].casecmp("true") == 0 }
end

kagent_sudoers "sklearn_serving" do 
  user          node['glassfish']['user']
  group         "root"
  script_name   "sklearn_serving.sh"
  template      "sklearn_serving.sh.erb"
  run_as        "ALL" # run this as root - inside we change to different users 
  not_if       { node['install']['kubernetes'].casecmp("true") == 0 }
end

kagent_sudoers "jupyter-project-cleanup" do 
  user          node['glassfish']['user']
  group         "root"
  script_name   "jupyter-project-cleanup.sh"
  template      "jupyter-project-cleanup.sh.erb"
  run_as        "ALL"
  not_if       { node['install']['kubernetes'].casecmp("true") == 0 }
end

kagent_sudoers "git" do
  user          node['glassfish']['user']
  group         "root"
  script_name   "git.sh"
  template      "git.sh.erb"
  run_as        "ALL" # run this as root - inside we change to different users
end

docker_cgroup_restart_script="docker-cgroup-rewrite.sh"
kagent_sudoers "docker-cgroup-rewrite" do
  user          node['glassfish']['user']
  group         "root"
  script_name   "#{docker_cgroup_restart_script}"
  template      "#{docker_cgroup_restart_script}.erb"
  run_as        "ALL"
end

kagent_sudoers "testconnector" do
  user          node['glassfish']['user']
  group         "root"
  script_name   "testconnector-launch.sh"
  template      "testconnector-launch.sh.erb"
  run_as        "ALL" # run this as root - inside we change to different users
end

registry_addr = { :registry_addr => consul_helper.get_service_fqdn("registry") + ":#{node['hops']['docker']['registry']['port']}"}
kagent_sudoers "dockerImage" do
  user          node['glassfish']['user']
  group         "root"
  script_name   "dockerImage.sh"
  template      "dockerImage.sh.erb"
  variables     registry_addr
  run_as        "ALL" # run this as root - inside we change to different users
end

command=""
case node['platform']
 when 'debian', 'ubuntu'
   command='tensorflow_model_server'
 when 'redhat', 'centos', 'fedora'
   command='/opt/serving/bazel-bin/tensorflow_serving/model_servers/tensorflow_model_server'
end

template "#{theDomain}/bin/tfserving-launch.sh" do
  source "tfserving-launch.sh.erb"
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode "550"
  variables({
     :command => command
  })
  action :create
end

["tensorboard-launch.sh", "tensorboard-cleanup.sh", "condasearch.sh", "list_environment.sh", "jupyter-kill.sh",
"tfserving-kill.sh", "sklearn_serving-launch.sh", "sklearn_serving-kill.sh", "git-container-kill.sh"].each do |script|
  template "#{theDomain}/bin/#{script}" do
    source "#{script}.erb"
    owner node['glassfish']['user']
    group node['glassfish']['group']
    mode "500"
    action :create
  end
end

template "#{theDomain}/bin/jupyter-launch.sh" do
  source "jupyter-launch.sh.erb"
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode "500"
  action :create
  variables({
              :namenode_fdqn => namenode_fdqn,
            })
end

template "#{theDomain}/bin/git-container-launch.sh" do
  source "git-container-launch.sh.erb"
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode "500"
  action :create
  variables({
              :glassfish_fdqn => glassfish_fdqn,
              :namenode_fdqn => namenode_fdqn,
            })
end

["sklearn_flask_server.py"].each do |script|
  template "#{theDomain}/bin/#{script}" do
    source "#{script}.erb"
    owner node['glassfish']['user']
    group node['glassfish']['group']
    mode "750"
    action :create
  end
end

# Hopsworks user should own the directory so that hopsworks code
# can create the template files needed for Jupyter.
# Hopsworks will use a sudoer script to launch jupyter as the 'jupyter' user.
# The jupyter user will be able to read the files and write to the directories due to group permissions

user node['hops']['yarnapp']['user'] do
  uid node['hops']['yarnapp']['uid']
  gid node['hops']['group']
  system true
  manage_home true
  shell "/bin/bash"
  action :create
  not_if "getent passwd #{node['hops']['yarnapp']['user']}"
  not_if { node['install']['external_users'].casecmp("true") == 0 }
end

#update permissions of base_dir to 770
directory node["jupyter"]["base_dir"]  do
  owner node["jupyter"]["user"]
  group node["jupyter"]["group"]
  mode "770"
  action :create
end

flyway_tgz = File.basename(node['hopsworks']['flyway_url'])
flyway =  "flyway-" + node['hopsworks']['flyway']['version']

remote_file "#{Chef::Config['file_cache_path']}/#{flyway_tgz}" do
  user node['glassfish']['user']
  group node['glassfish']['group']
  source node['hopsworks']['flyway_url']
  mode 0755
  action :create
end

bash "unpack_flyway" do
  user "root"
  code <<-EOF
    set -e
    cd #{Chef::Config['file_cache_path']}
    tar -xzf #{flyway_tgz}
    mv #{flyway} #{theDomain}
    cd #{theDomain}
    chown -R #{node['glassfish']['user']} flyway*
    if [ -L flyway ]; then
      cp -r flyway/sql #{flyway}/ 
      rm -rf flyway
    fi
    ln -s #{flyway} flyway
  EOF
  not_if { Dir.exist?("#{theDomain}/#{flyway}")}
end

template "#{theDomain}/flyway/conf/flyway.conf" do
  source "flyway.conf.erb"
  owner node['glassfish']['user']
  mode 0750
  action :create
end

directory "#{theDomain}/flyway/dml" do
  owner node['glassfish']['user']
  mode "770"
  action :create
end

directory "#{theDomain}/flyway/all" do
  owner node['glassfish']['user']
  mode "770"
  action :create
end

directory "#{theDomain}/flyway/all/sql" do
  owner node['glassfish']['user']
  mode "770"
  action :create
end

template "#{domains_dir}/#{domain_name}/config/login.conf" do
  cookbook 'hopsworks'
  source "login.conf.erb"
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode "0600"
  action :create
end

if node['kerberos']['enabled'].to_s == "true" && !node['kerberos']['krb_conf_path'].to_s.empty?
  krb_conf_path = node['kerberos']['krb_conf_path']
  remote_file "#{theDomain}/config/krb5.conf" do
    source "file:///#{krb_conf_path}"
    owner node['glassfish']['user']
    group node['glassfish']['group']
    mode "0600"
    action :create
  end
end

if node['kerberos']['enabled'].to_s == "true" && !node['kerberos']['krb_server_key_tab_path'].to_s.empty?
  key_tab_path = node['kerberos']['krb_server_key_tab_path']
  ket_tab_name = node['kerberos']['krb_server_key_tab_name']
  remote_file "#{theDomain}/config/#{ket_tab_name}" do
    source "file:///#{key_tab_path}"
    owner node['glassfish']['user']
    group node['glassfish']['group']
    mode "0600"
    action :create
  end
end

if conda_helpers.is_upgrade && Gem::Version.new(node['install']['current_version']) < Gem::Version.new('3.1.0')
  # We need to restore the internal certificates and the flyway schemas for the upgrade
  # To be successfull
  bash 'Move old certificates and flyway schemas' do
    user 'root'
    code <<-EOH
      set -e
      cp -p #{node['hopsworks']['domains_dir']}4/domain1/config/internal* #{node['hopsworks']['config_dir']}/
      cp -p #{node['hopsworks']['config_dir']}/internal_bundle.crt #{node['hopsworks']['config_dir']}/certificate_bundle.pem

      # Hardcoded because the attribute doesn't exists anymore
      cp #{node['hopsworks']['dir']}/certs-dir/certs/ca.cert.pem #{node['hopsworks']['config_dir']}/root_ca.pem

      cp -p #{node['hopsworks']['domains_dir']}4/domain1/flyway/sql/* #{theDomain}/flyway/sql/

      # Increase privileges on the old CA.certs.pem so that Hopsworks CA can initialize itself.
      chown #{node['hopsworks']['user']} /srv/hops/certs-dir/certs/ca.cert.pem
      chown #{node['hopsworks']['user']} /srv/hops/certs-dir/private/ca.key.pem
    EOH
    only_if { File.exists?("#{node['hopsworks']['domains_dir']}4")}
  end
end

#install cadvisor only on the headnode and no kubernetes
if (exists_local("hopsworks", "default")) && (node['install']['kubernetes'].casecmp?("false"))
  include_recipe "hopsworks::cadvisor"
end

hopsworks_user_home = conda_helpers.get_user_home(node['hopsworks']['user'])

template "#{hopsworks_user_home}/.condarc" do
  source "condarc.erb"
  cookbook "conda"
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode 0750
  variables({
    :pkgs_dirs => node['hopsworks']['conda_cache']
  })
  action :create
end

directory "#{hopsworks_user_home}/.pip" do
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode '0700'
  action :create
end

template "#{hopsworks_user_home}/.pip/pip.conf" do
  source "pip.conf.erb"
  cookbook "conda"
  owner node['glassfish']['user']
  group node['glassfish']['group']
  mode 0750
  action :create
end