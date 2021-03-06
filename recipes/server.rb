#
# Cookbook Name:: cinder
# Recipe:: server
#
# Copyright 2012, AT&T
# Copyright 2012, DreamHost
# Copyright 2012, Rackspace US, Inc.
# Copyright 2012, Opscode, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class ::Chef::Recipe
  include ::Openstack
end

# Allow for using a well known service password
if node["developer_mode"]
  node.set_unless["cinder"]["service_pass"] = "cinder"
else
  node.set_unless["cinder"]["service_pass"] = secure_password
end

platform_options = node["cinder"]["platform"]

platform_options["cinder_packages"].each do |pkg|
  package pkg do
    action :upgrade
  end
end

service "cinder-api" do
  service_name platform_options["cinder_api_service"]
  supports :status => true, :restart => true
  action :enable
end

service "cinder-scheduler" do
  service_name platform_options["cinder_scheduler_service"]
  supports :status => true, :restart => true
  action :enable
end

service "cinder-volume" do
  service_name platform_options["cinder_volume_service"]
  supports :status => true, :restart => true
  action :enable
end

directory "/etc/cinder" do
  action :create
  group "cinder"
  owner "cinder"
  mode "0700"
end


db_user = node['cinder']['db']['username']
db_pass = node['cinder']['db']['password']
sql_connection = db_uri("cinder", db_user, db_pass)

rabbit_server_role = node["cinder"]["rabbit_server_chef_role"]
rabbit_info = config_by_role rabbit_server_role, "queue"

identity_admin_endpoint = endpoint "identity-admin"
identity_endpoint = endpoint "identity-api"
keystone_service_role = node["cinder"]["keystone_service_chef_role"]
keystone = config_by_role keystone_service_role, "keystone"
glance = config_by_role node["glance"]["glance_api_chef_role"], "glance"
image_api_endpoint = endpoint "image-api"
api_endpoint = endpoint "compute-volume"

if glance["api"]["swift_store_auth_address"].nil?
  swift_store_auth_address=identity_admin_endpoint.to_s
  swift_store_user="#{glance["service_tenant_name"]}:#{glance["service_user"]}"
  swift_store_key=glance["service_pass"]
  swift_store_auth_version=2
else
  swift_store_auth_address=glance["api"]["swift_store_auth_address"]
  swift_store_user=glance["api"]["swift_store_user"]
  swift_store_key=glance["api"]["swift_store_key"]
  swift_store_auth_version=glance["api"]["swift_store_auth_version"]
end

template "/etc/cinder/cinder.conf" do
  source "cinder.conf.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(
    :sql_connection => sql_connection,
    :use_syslog => node["cinder"]["syslog"]["use"],
    :log_facility => node["cinder"]["syslog"]["facility"],
    :rabbit_ipaddress => rabbit_info["host"],
    :rabbit_port => rabbit_info["port"],
    :default_store => glance["api"]["default_store"],
    :swift_store_key => swift_store_key,
    :swift_store_user => swift_store_user,
    :swift_store_auth_address => swift_store_auth_address,
    :swift_store_auth_version => swift_store_auth_version,
    :swift_large_object_size => glance["api"]["swift"]["store_large_object_size"],
    :swift_large_object_chunk_size => glance["api"]["swift"]["store_large_object_chunk_size"],
    :swift_store_container => glance["api"]["swift"]["store_container"],
    :keystone_api_ipaddress => identity_endpoint.host,
    :keystone_service_port => identity_endpoint.port,
    :keystone_admin_port => identity_endpoint.port,
    :keystone_admin_token => keystone["admin_token"],
    :glance_api_ipaddress => image_api_endpoint.host,
    :glance_service_port => image_api_endpoint.port,
    :glance_admin_port => image_api_endpoint.port,
    :glance_admin_token => glance["admin_token"],
    :service_tenant_name => node["cinder"]["service_tenant_name"],
    :service_user => node["cinder"]["service_user"],
    :service_pass => node["cinder"]["service_pass"]
    )
  notifies :restart, resources(:service => "cinder-api"), :immediately
  notifies :restart, resources(:service => "cinder-scheduler"), :immediately
  notifies :restart, resources(:service => "cinder-volume"), :immediately
end

execute "cinder-manage db sync" do
  command "cinder-manage db sync"
  action :run
  not_if "cinder-manage db version && test $(cinder-manage db version) -gt 0"
end

template "/etc/cinder/api-paste.ini" do
  source "api-paste.ini.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(
    "use_syslog" => node["cinder"]["syslog"]["use"],
    "log_facility" => node["cinder"]["syslog"]["facility"],
    "keystone_api_ipaddress" => identity_endpoint.host,
    "keystone_service_port" => identity_endpoint.port,
    "keystone_admin_port" => identity_endpoint.port,
    "keystone_admin_token" => keystone["admin_token"],
    "service_tenant_name" => node["cinder"]["service_tenant_name"],
    "service_user" => node["cinder"]["service_user"],
    "service_pass" => node["cinder"]["service_pass"]
    )
  notifies :restart, resources(:service => "cinder-api"), :immediately
  notifies :restart, resources(:service => "cinder-scheduler"), :immediately
  notifies :restart, resources(:service => "cinder-volume"), :immediately
end

# Register Cinder Volume Service
keystone_register "Register Cinder Volume Service" do
  auth_host identity_admin_endpoint.host
  auth_port identity_admin_endpoint.port.to_s
  auth_protocol identity_admin_endpoint.scheme
  api_ver identity_admin_endpoint.path
  auth_token keystone["admin_token"]
  service_name "cinder"
  service_type "volume"
  service_description "Cinder Volume Service"
  endpoint_region "RegionOne"
  endpoint_adminurl api_endpoint.to_s
  endpoint_internalurl api_endpoint.to_s
  endpoint_publicurl api_endpoint.to_s
  action :create_service
end
keystone_register "Register Cinder Volume Endpoint" do
  auth_host identity_admin_endpoint.host
  auth_port identity_admin_endpoint.port.to_s
  auth_protocol identity_admin_endpoint.scheme
  api_ver identity_admin_endpoint.path
  auth_token keystone["admin_token"]
  service_name "cinder"
  service_type "volume"
  service_description "Cinder Volume Service"
  endpoint_region "RegionOne"
  endpoint_adminurl api_endpoint.to_s
  endpoint_internalurl api_endpoint.to_s
  endpoint_publicurl api_endpoint.to_s
  action :create_endpoint
end

