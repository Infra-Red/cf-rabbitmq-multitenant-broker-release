require 'spec_helper'

require 'json'
require 'ostruct'
require 'tempfile'
require 'net/https'
require 'uri'

require 'prof/marketplace_service'
require 'prof/service_instance'
require 'prof/cloud_foundry'
require 'prof/test_app'
require 'rabbitmq/http/client'

require "mqtt"
require "stomp"
require 'net/https'
require 'httparty'

require File.expand_path('../../../assets/rabbit-labrat/lib/lab_rat/aggregate_health_checker.rb', __FILE__)

RSpec.describe 'Using a Cloud Foundry service broker' do
  let(:service_name) { 'p-rabbitmq' }
  let(:service_offering) { 'standard' }

  let(:service) do
    Prof::MarketplaceService.new(
      name: service_name,
      plan: 'standard'
    )
  end

  let(:rmq_server_admin_broker_username) do
    rabbitmq_server_instance_group = manifest['instance_groups'].select{ |instance_group| instance_group['name'] == 'rmq' }.first
    rabbitmq_server_job =  rabbitmq_server_instance_group['jobs'].select{ |job| job['name'] == 'rabbitmq-server'}.first
    rabbitmq_server_job['properties']['administrators']['broker']['username']
  end

  let(:rmq_server_admin_broker_password) do
    rabbitmq_server_instance_group = manifest['instance_groups'].select{ |instance_group| instance_group['name'] == 'rmq' }.first
    rabbitmq_server_job =  rabbitmq_server_instance_group['jobs'].select{ |job| job['name'] == 'rabbitmq-server'}.first
    rabbitmq_server_job['properties']['administrators']['broker']['password']
  end

  let(:rmq_broker_username) do
    rabbitmq_broker_registrar_instance_group = test_manifest['instance_groups'].select{ |instance_group| instance_group['name'] == 'broker-registrar' }.first
    rabbitmq_broker_registrar_job =  rabbitmq_broker_registrar_instance_group['jobs'].select{ |job| job['name'] == 'broker-registrar'}.first
    rabbitmq_broker_registrar_properties = rabbitmq_broker_registrar_job['properties']['broker']
    rabbitmq_broker_registrar_properties[ 'username' ]
  end

  let(:rmq_broker_password) do
    rabbitmq_broker_registrar_instance_group = test_manifest['instance_groups'].select{ |instance_group| instance_group['name'] == 'broker-registrar' }.first
    rabbitmq_broker_registrar_job =  rabbitmq_broker_registrar_instance_group['jobs'].select{ |job| job['name'] == 'broker-registrar'}.first
    rabbitmq_broker_registrar_properties = rabbitmq_broker_registrar_job['properties']['broker']
    rabbitmq_broker_registrar_properties[ 'password' ]
  end

  let(:rmq_broker_host) do
    rabbitmq_broker_registrar_instance_group = test_manifest['instance_groups'].select{ |instance_group| instance_group['name'] == 'broker-registrar' }.first
    rabbitmq_broker_registrar_job =  rabbitmq_broker_registrar_instance_group['jobs'].select{ |job| job['name'] == 'broker-registrar'}.first
    rabbitmq_broker_registrar_properties = rabbitmq_broker_registrar_job['properties']['broker']
    protocol = rabbitmq_broker_registrar_properties[ 'protocol' ]
    host = rabbitmq_broker_registrar_properties[ 'host' ]
    URI.parse("#{protocol}://#{host}")
  end

  let(:broker_catalog) do
    catalog_uri = URI.join(rmq_broker_host, '/v2/catalog')
    req = Net::HTTP::Get.new(catalog_uri)
    req.basic_auth(rmq_broker_username, rmq_broker_password)
    response = Net::HTTP.start(rmq_broker_host.hostname, rmq_broker_host.port, :use_ssl => rmq_broker_host.scheme == 'https', :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|
      http.request(req)
    end
    JSON.parse(response.body)
  end

  context 'default deployment'  do
    fit 'provides default connectivity', :pushes_cf_app do
      app_name = 'test_app'
      service_instance_name = 'test_service_name'

      cf2.push_app(test_app_path, app_name)
      cf2.create_service_instance(service_name, service_offering, service_instance_name)
      cf2.bind_app_to_service(app_name, service_instance_name)

      cf2.start_app(app_name)

      provides_amqp_connectivity(app)
      provides_mqtt_connectivity(app)
      provides_stomp_connectivity(app)

      # cf2.push_app_and_bind_with_service(test_app, service) do |app, _|
      #   provides_amqp_connectivity(app)
      #   provides_mqtt_connectivity(app)
      #   provides_stomp_connectivity(app)
      # end
    end

    it 'fails to connect if bindings are deleted', :pushes_cf_app do
      cf.push_app_and_bind_with_service(test_app, service) do |app, service_instance|
        cf.unbind_app_from_service(app, service_instance)

        provides_no_amqp_connectivity(app)
        provides_no_mqtt_connectivity(app)
 
        # Check #150334805
        # provides_no_stomp_connectivity(app)
      end
    end
  end

  context 'when stomp plugin is disabled'  do
    before(:context) do
      bosh.redeploy do |manifest|
        rabbitmq_server_instance_group = manifest['instance_groups'].select{ |instance_group| instance_group['name'] == 'rmq' }.first
        rabbitmq_server_job =  rabbitmq_server_instance_group['jobs'].select{ |job| job['name'] == 'rabbitmq-server'}.first
        service_properties = rabbitmq_server_job['properties']['rabbitmq-server']['plugins'] = ['rabbitmq_management','rabbitmq_mqtt']
      end
    end

    after(:context) do
      bosh.deploy(test_manifest)
    end

    it 'provides only amqp and mqtt connectivity', :pushes_cf_app do
      cf.push_app_and_bind_with_service(test_app, service) do |app, _|
        provides_amqp_connectivity(app)
        provides_mqtt_connectivity(app)
        provides_no_stomp_connectivity(app)
      end
    end
  end

  context 'when broker is configured with HA policy' do
    before(:context) do
      bosh.redeploy do |manifest|
        rabbitmq_broker_instance_group = manifest['instance_groups'].select{ |instance_group| instance_group['name'] == 'rmq-broker' }.first
        rabbitmq_broker_job =  rabbitmq_broker_instance_group['jobs'].select{ |job| job['name'] == 'rabbitmq-broker'}.first
        service_properties = rabbitmq_broker_job['properties']['rabbitmq-broker']['rabbitmq']['operator_set_policy'] = {
          'enabled' => true,
          'policy_name' => "operator_set_policy",
          'policy_definition' => "{\"ha-mode\":\"exactly\",\"ha-params\":2,\"ha-sync-mode\":\"automatic\"}",
          'policy_priority' => 50
        }
      end
    end

    after(:context) do
      bosh.deploy(test_manifest)
    end

    it 'sets queue policy to each created service instance', :pushes_cf_app do
      cf.push_app_and_bind_with_service(test_app, service) do |app, _|
        provides_mirrored_queue_policy_as_a_default(app)
      end
    end
  end

  context 'when provisioning a service key' do
    it 'provides defaults', :creates_service_key do
      cf.provision_and_create_service_key(service) do |service_instance, service_key, service_key_data|
        check_that_amqp_connection_data_is_present_in(service_key_data)
        check_that_stomp_connection_data_is_present_in(service_key_data)
      end
    end
  end

  context 'when deprovisioning a service key' do
    it 'is no longer listed in service-keys', :creates_service_key do
      cf.provision_and_create_service_key(service) do |service_instance, service_key, service_key_data|
        @service_instance = service_instance
        @service_key = service_key
        @service_key_data = service_key_data

        cf.delete_service_key(@service_instance, @service_key)

        expect(cf.list_service_keys(@service_instance)).to_not include(@service_key)
      end
    end
  end

  context 'when broker is configured' do
    context 'when the service broker is configured with particular service metadata' do
      let(:service_info) { broker_catalog['services'].first }
      let(:broker_catalog_metadata) { service_info['metadata'] }

      before(:all) do
        bosh.redeploy do |manifest|
          rabbitmq_broker_instance_group = manifest['instance_groups'].select{ |instance_group| instance_group['name'] == 'rmq-broker' }.first
          rabbitmq_broker_job =  rabbitmq_broker_instance_group['jobs'].select{ |job| job['name'] == 'rabbitmq-broker'}.first
          service_properties = rabbitmq_broker_job['properties']['rabbitmq-broker']['service']
          service_properties['name'] = "service-name"
          service_properties['display_name'] = "apps-manager-test-name"
          service_properties['offering_description'] = "Some description of our service"
          service_properties['long_description'] = "Some long description of our service"
          service_properties['icon_image'] = "image-uri"
          service_properties['provider_display_name'] = "CompanyName"
          service_properties['documentation_url'] = "https://documentation.url"
          service_properties['support_url'] = "https://support.url"
        end
      end

      after(:all) do
        bosh.deploy(test_manifest)
      end

      describe 'the catalog' do
        it 'has the correct name' do
          expect(service_info['name']).to eq("service-name")
        end

        it 'has the correct description' do
          expect(service_info['description']).to eq("Some description of our service")
        end

        it 'has the correct display name' do
          expect(broker_catalog_metadata['displayName']).to eq("apps-manager-test-name")
        end

        it 'has the correct long description' do
          expect(broker_catalog_metadata['longDescription']).to eq("Some long description of our service")
        end

        it 'has the correct image icon' do
          expect(broker_catalog_metadata['imageUrl']).to eq("data:image/png;base64,image-uri")
        end

        it 'has the correct provider display name' do
          expect(broker_catalog_metadata['providerDisplayName']).to eq("CompanyName")
        end

        it 'has the correct documentation url' do
          expect(broker_catalog_metadata['documentationUrl']).to eq("https://documentation.url")
        end

        it 'has the correct support url' do
          expect(broker_catalog_metadata['supportUrl']).to eq("https://support.url")
        end
      end
    end
  end
end

def get(url)
  HTTParty.get(url, {verify: false, timeout: 2})
end

def provides_amqp_connectivity(app)
  response = get("#{app.url}/services/rabbitmq/protocols/amqp091")
  expect(response.code).to eql(200)
  expect(response.body).to include('amq.gen')
end

def provides_mqtt_connectivity(app)
  response = get("#{app.url}/services/rabbitmq/protocols/mqtt")

  expect(response.code).to eql(200)
  expect(response.body).to include('mqtt://')
  expect(response.body).to include('Payload published')
end

def provides_stomp_connectivity(app)
  response = get("#{app.url}/services/rabbitmq/protocols/stomp")

  expect(response.code).to eql(200)
  expect(response.body).to include('Payload published')
end

def provides_no_amqp_connectivity(app)
  provides_no_connectivity_for(app, 'amqp091')
end

def provides_no_mqtt_connectivity(app)
  provides_no_connectivity_for(app, 'mqtt')
end

def provides_no_stomp_connectivity(app)
  provides_no_connectivity_for(app, 'stomp')
end

def provides_no_connectivity_for(app, protocol)
  # This is a work-around for #144893311
  begin
    response = get("#{app.url}/services/rabbitmq/protocols/#{protocol}")
    expect(response.code).to eql(500)
  rescue Net::ReadTimeout => e
    puts "Caught exception #{e}!"
  end
end

def check_that_amqp_connection_data_is_present_in(service_key_data)
  check_connection_data(service_key_data, 'amqp', 5672)
end

def check_that_stomp_connection_data_is_present_in(service_key_data)
  check_connection_data(service_key_data, 'stomp', 61613)
end

def check_connection_data(service_key_data, protocol, port)
  expect(service_key_data).to have_key('protocols')
  expect(service_key_data['protocols']).to have_key(protocol)
  expect(service_key_data['protocols'][protocol]).to have_key('uri')
  expect(service_key_data['protocols'][protocol]['uri']).to start_with("#{protocol}://")
  expect(service_key_data['protocols'][protocol]).to have_key('host')
  expect(service_key_data['protocols'][protocol]['host']).not_to be_empty
  expect(service_key_data['protocols'][protocol]).to have_key('port')
  expect(service_key_data['protocols'][protocol]['port']).to eq(port)
  expect(service_key_data['protocols'][protocol]).to have_key('username')
  expect(service_key_data['protocols'][protocol]['username']).not_to be_empty
  expect(service_key_data['protocols'][protocol]).to have_key('password')
  expect(service_key_data['protocols'][protocol]['password']).not_to be_empty
  expect(service_key_data['protocols'][protocol]).to have_key('vhost')
  expect(service_key_data['protocols'][protocol]['vhost']).not_to be_empty
end

def provides_mirrored_queue_policy_as_a_default(app)
  vcap_services = cf.app_vcap_services(app.name)
  credentials = vcap_services[service_name].first['credentials']
  http_api_uris = credentials['http_api_uris']
  vhost = credentials['vhost']

  client = RabbitMQ::HTTP::Client.new(http_api_uris.first, ssl: { verify: false })
  policy = client.list_policies(vhost).find do |policy|
    policy['name'] == 'operator_set_policy'
  end

  expect(policy).to_not be_nil
  expect(policy['pattern']).to eq('.*')
  expect(policy['apply-to']).to eq('all')
  expect(policy['definition']).to eq('ha-mode' => 'exactly', 'ha-params' => 2, 'ha-sync-mode' => 'automatic')
  expect(policy['priority']).to eq(50)
end
