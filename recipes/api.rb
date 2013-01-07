#
# Cookbook Name:: cinder
# Recipe:: api
#
# Copyright 2012, Rackspace US, Inc.
# Copyright 2012, AT&T, Inc.
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

require "uri"

class ::Chef::Recipe
  include ::Openstack
end

platform_options = node["cinder"]["platform"]

platform_options["cinder_api_packages"].each do |pkg|
  package pkg do
    options platform_options["package_overrides"]

    action :upgrade
  end
end

service "cinder-api" do
  service_name platform_options["cinder_api_service"]
  supports :status => true, :restart => true

  action :enable
end

execute "cinder-manage db sync" do
  command "cinder-manage db sync"

  action :nothing
end

db_user = node["cinder"]["db"]["username"]
db_pass = db_password "cinder"
sql_connection = db_uri("volume", db_user, db_pass)

rabbit_server_role = node["cinder"]["rabbit_server_chef_role"]
rabbit_info = config_by_role rabbit_server_role, "queue"

glance_api_role = node["cinder"]["glance_api_chef_role"]
glance = config_by_role glance_api_role, "glance"
glance_api_endpoint = endpoint "image-api"

keystone_service_role = node["cinder"]["keystone_service_chef_role"]
keystone = config_by_role keystone_service_role, "keystone"
identity_admin_endpoint = endpoint "identity-admin"

# Instead of the search to find the keystone service, put this
# into openstack-common as a common attribute?
ksadmin_user = keystone["admin_user"]
ksadmin_tenant_name = keystone["admin_tenant_name"]
ksadmin_pass = user_password ksadmin_user
raw_auth_uri = ::URI.decode identity_admin_endpoint
auth_uri = raw_auth_uri.to_s

cinder_api_endpoint = endpoint "volume-api"
service_pass = service_password "cinder"

template "/etc/cinder/cinder.conf" do
  source "cinder.conf.erb"
  group  node["cinder"]["group"]
  owner  node["cinder"]["user"]
  mode   00644
  variables(
    :sql_connection => sql_connection,
    :rabbit_host => rabbit_info["host"],
    :rabbit_port => rabbit_info["port"],
    :glance_host => glance_api_endpoint.host,
    :glance_port => glance_api_endpoint.port
  )

  notifies :restart, resources(:service => "cinder-api"), :delayed
end

template "/etc/cinder/api-paste.ini" do
  source "api-paste.ini.erb"
  group  node["cinder"]["group"]
  owner  node["cinder"]["user"]
  mode   00644
  variables(
    :raw_auth_uri => raw_auth_uri,
    :auth_uri => auth_uri,
    :service_pass => service_pass
  )

  notifies :restart, resources(:service => "cinder-api"), :immediately
end

keystone_register "Register Cinder Volume Service" do
  auth_uri auth_uri
  admin_user ksadmin_user
  admin_tenant_name ksadmin_tenant_name
  admin_password ksadmin_pass
  service_name "cinder"
  service_type "volume"
  service_description "Cinder Volume Service"
  endpoint_region node["cinder"]["region"]
  endpoint_adminurl ::URI.decode cinder_api_endpoint.to_s
  endpoint_internalurl ::URI.decode cinder_api_endpoint.to_s
  endpoint_publicurl ::URI.decode cinder_api_endpoint.to_s

  action :create_service
end

keystone_register "Register Cinder Volume Endpoint" do
  auth_uri auth_uri
  admin_user ksadmin_user
  admin_tenant_name ksadmin_tenant_name
  admin_password ksadmin_pass
  service_name "cinder"
  service_type "volume"
  service_description "Cinder Volume Service"
  endpoint_region node["cinder"]["region"]
  endpoint_adminurl ::URI.decode cinder_api_endpoint.to_s
  endpoint_internalurl ::URI.decode cinder_api_endpoint.to_s
  endpoint_publicurl ::URI.decode cinder_api_endpoint.to_s

  action :create_endpoint
end

keystone_register "Register Cinder Service User" do
  auth_uri auth_uri
  admin_user ksadmin_user
  admin_tenant_name ksadmin_tenant_name
  admin_password ksadmin_pass
  tenant_name node["cinder"]["service_tenant_name"]
  user_name node["cinder"]["service_user"]
  user_pass node["cinder"]["service_pass"]
  user_enabled "true" # Not required as this is the default
  action :create_user
end

keystone_register "Grant service Role to Cinder Service User for Cinder Service Tenant" do
  auth_uri auth_uri
  admin_user ksadmin_user
  admin_tenant_name ksadmin_tenant_name
  admin_password ksadmin_pass
  tenant_name node["cinder"]["service_tenant_name"]
  user_name node["cinder"]["service_user"]
  role_name node["cinder"]["service_role"]
  action :grant_role
end
