#!/usr/bin/env ruby

# This script accepts a config to generate Airwall invitations for a given list of emails.
# The output after the invites are sent will be a hash of the email the invite was sent to, to the id of the invite
# recipient and activation_code

require 'optparse'
require 'net/http'
require 'json'
require 'fileutils'
require 'time'
require 'openssl'

class String
  # colorization
  def colorize(color_code)
    "\e[#{color_code}m#{self}\e[0m"
  end

  def red
    colorize(31)
  end

  def green
    colorize(32)
  end

  def yellow
    colorize(33)
  end
end

class Request
  def initialize(host, headers)
    @host = host
    @headers = headers
  end

  def http_get(path)
    req = Net::HTTP::Get.new(path, @headers)
    http_req(req)
  end

  def http_post(path, payload = nil)
    req = Net::HTTP::Post.new(path, @headers)
    req.body = payload.to_json unless payload.nil?
    http_req(req)
  end

  def http_delete(path, payload = nil)
    req = Net::HTTP::Delete.new(path, @headers)
    req.body = payload.to_json unless payload.nil?
    http_req(req)
  end

  def http_req(req)
    h = Net::HTTP.new(@host, 443)
    h.use_ssl = true
    h.verify_mode = OpenSSL::SSL::VERIFY_NONE

    h.start do |http|
      http.open_timeout = 60
      http.read_timeout = 60
      http.request(req)
    end
  end
end

# returns hash like { <user_email>: { id: <recipient id>, activation_code: <activation_code> }}
def create_invites(config)
  return if config.nil?

  data = { method: 'email' }

  # add all optional keys if they exist
  optional_keys = %w(device_group_ids hipservice_group_ids overlay_network_ids conductor_url profile_name name_schema
                    overlay_ip_network config_tag_ids email_message email_subject emails)
  optional_keys.each{ |k| data[k] = config[k] if config.has_key?(k) }

  # accept expires_at ISO8601 date-time format string or days_valid and convert to ISO8601
  if config['days_valid']
    expiration = Time.now + ((60 * 60 * 24) * config['days_valid'])
    data[:expires_at] = expiration.iso8601
  elsif config['expires_at']
    data[:expires_at] = config['expires_at']
  end


  result = {}

  url = "/api/v1/invites"
  response = @req.http_post(url, data)
  if ['201'].include?(response.code)
    body = JSON.parse(response.body)
    body['hip_invite_recipients'].each do |recip|
      result[recip['email']] = { id: recip['id'], activation_code: recip['activation_code'] }
    end
  else
    puts("ERROR: could not create invites: #{response.body}")
    exit(1)
  end
  result
end

# ------------------- main ---------------------

ARGV << '-h' if ARGV.empty?

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: gen_invites.rb [config]"

  opts.on("-c [config_file]", "--config-file [config_file]", "Path to JSON config file") do |config|
    options['config'] = config
  end

  opts.on("-o [output_file]", "--output-file [output_file]", "Path to output file") do |out_file|
    options['out_file'] = out_file
  end

  opts.on("-h", "--help", "Display help") do
    puts opts
    exit
  end
end.parse!

config = options['config'] || ARGV.shift

unless ARGV.empty?
  puts("ERROR: Unknown option(s) #{ARGV.join(', ')}".red)
  exit(1)
end

unless File.file?(config)
  puts("ERROR: could not find config file '#{config}'".red)
  exit(1)
end

config_params = JSON.parse(File.read(config)) rescue nil
if config_params.nil?
  puts("ERROR: failed to parse config in #{config}".red)
  exit(1)
end

# if out_file set via command line, use that value, otherwise check in config file, if neither write to stdout
out_file = options['out_file'].nil? ? config_params['out_file'] : options['out_file']

# validate API config params
conductor = config_params['conductor_url']
if conductor.nil? || !conductor.is_a?(String)
  puts("ERROR: config param conductor_url must be a valid string".red)
  exit(1)
end

client_id = config_params['client_id']
if client_id.nil? || !client_id.is_a?(String)
  puts("ERROR: config param client_id must be a valid string".red)
  exit(1)
end

api_token = config_params['api_token']
if api_token.nil? || !api_token.is_a?(String)
  puts("ERROR: config param api_token must be a valid string".red)
  exit(1)
end

# initialize request object for API calls
headers = {
    'Content-Type' => 'application/json',
    'Accept' => 'application/json',
    'X-API-Client-ID' => client_id,
    'X-API-Token' => api_token
}
@req = Request.new(conductor, headers)

emails_activation_codes = create_invites(config_params)

if !out_file.nil?
  out = File.open(out_file, 'w')
  out.write(emails_activation_codes.to_json)
else
  puts(emails_activation_codes.to_json)
end

exit(0)
