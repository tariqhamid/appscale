# Programmer: Navraj Chohan <nlake44@gmail.com>
require 'djinn'
require 'djinn_job_data'
require 'helperfunctions'
require 'monit_interface'


# A Fixnum that indicates which port the Thrift service binds to, by default.
# Note that this class does not dictate what port it binds to - change this
# constant and the template file that dictates to change this port.
THRIFT_PORT = 9160


# A String that indicates where we write the process ID that Cassandra runs
# on at this machine.
PID_FILE = "/var/appscale/appscale-cassandra.pid"


# A String that indicates where we install Cassandra on this machine.
CASSANDRA_DIR = "/opt/cassandra"


# A String that indicates where the Cassandra binary is located on this
# machine.
CASSANDRA_EXECUTABLE = "#{CASSANDRA_DIR}/cassandra/bin/cassandra"


# A directory containing Cassandra-related scripts and libraries.
CASSANDRA_ENV_DIR = "#{APPSCALE_HOME}/AppDB/cassandra_env"

# The location of the setup cassandra config files script.
SETUP_CASSANDRA_CONFIG_SCRIPT = "python ~/appscale/scripts/setup_cassandra_config_files.py"

# The default port over which Cassandra will be available for JMX connections
JMX_PORT = "7070"

# Determines if a UserAppServer should run on this machine.
#
# Args:
#   job: A DjinnJobData that indicates if the node runs a Database role.
#
# Returns:
#   true if the given node runs a Database role, and false otherwise.
def has_soap_server?(job)
  if job.is_db_master? or job.is_db_slave?
    return true
  else
    return false
  end
end


# Calculates the token that should be set on this machine, which dictates how
# data should be partitioned between machines.
#
# Args:
#   master_ip: A String corresponding to the private FQDN or IP address of the
#     machine hosting the Database Master role.
#   slave_ips: An Array of Strings, where each String corresponds to a private
#     FQDN or IP address of a machine hosting a Database Slave role.
# Returns:
#   A Fixnum that corresponds to the token that should be used on this machine's
#   Cassandra configuration.
def get_local_token(master_ip, slave_ips)
  return if master_ip == HelperFunctions.local_ip

  slave_ips.each_with_index { |ip, index|
    # This token generation was taken from:
    # http://www.datastax.com/docs/0.8/install/cluster_init#cluster-init
    if ip == HelperFunctions.local_ip
      # Add one to offset the master
      return (index + 1)*(2**127)/(1 + slave_ips.length)
    end
  }
end


# Writes all the configuration files necessary to start Cassandra on this
# machine.
#
# Args:
#   master_ip: A String corresponding to the private FQDN or IP address of the
#     machine hosting the Database Master role.
#   slave_ips: An Array of Strings, where each String corresponds to a private
#     FQDN or IP address of a machine hosting a Database Slave role.
#   replication: The desired level of replication.
def setup_db_config_files(master_ip, slave_ips, replication)
  local_token = get_local_token(master_ip, slave_ips)
  local_ip = HelperFunctions.local_ip
  Djinn.log_run("#{SETUP_CASSANDRA_CONFIG_SCRIPT} --local-ip #{local_ip} " +
    "--master-ip #{master_ip} --local-token #{local_token} --replication #{replication} " +
    "--jmx-port #{JMX_PORT}")
end


# Starts Cassandra on this machine. Because this machine runs the DB Master
# role, it starts Cassandra first.
#
# Args:
#   clear_datastore: Remove any pre-existent data in the database.
def start_db_master(clear_datastore)
  @state = "Starting up Cassandra on the head node"
  Djinn.log_info("Starting up Cassandra as master")
  start_cassandra(clear_datastore)
end


# Starts Cassandra on this machine. This is identical to starting Cassandra as a
# Database Master role, with the extra step of waiting for the DB Master to boot
# Cassandra up.
#
# Args:
#   clear_datastore: Remove any pre-existent data in the database.
def start_db_slave(clear_datastore)
  @state = "Waiting for Cassandra to come up"
  Djinn.log_info("Starting up Cassandra as slave")

  HelperFunctions.sleep_until_port_is_open(Djinn.get_db_master_ip, THRIFT_PORT)
  Kernel.sleep(5)
  start_cassandra(clear_datastore)
end


# Starts Cassandra, and waits for it to start the Thrift service locally.
#
# Args:
#   clear_datastore: Remove any pre-existent data in the database.
def start_cassandra(clear_datastore)
  Djinn.log_run("pkill ThriftBroker")
  if clear_datastore
    Djinn.log_info("Erasing datastore contents")
    Djinn.log_run("rm -rf /opt/appscale/cassandra*")
    Djinn.log_run("rm /var/log/appscale/cassandra/system.log")
  end

  # TODO: Consider a more graceful stop command than this, which does a kill -9.
  start_cmd = "#{CASSANDRA_EXECUTABLE} start -p #{PID_FILE}"
  stop_cmd = "/usr/bin/python2 #{APPSCALE_HOME}/scripts/stop_service.py java cassandra"
  match_cmd = "/opt/cassandra"
  MonitInterface.start(:cassandra, start_cmd, stop_cmd, ports=9999, env_vars=nil,
    match_cmd=match_cmd)
  HelperFunctions.sleep_until_port_is_open(HelperFunctions.local_ip,
    THRIFT_PORT)
end

# Kills Cassandra on this machine.
def stop_db_master
  Djinn.log_info("Stopping Cassandra master")
  MonitInterface.stop(:cassandra)
end


# Kills Cassandra on this machine.
def stop_db_slave
  Djinn.log_info("Stopping Cassandra slave")
  MonitInterface.stop(:cassandra)
end
