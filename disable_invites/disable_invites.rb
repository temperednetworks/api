#!/usr/bin/env ruby

require 'optparse'
require 'net/http'
require 'json'
require 'fileutils'

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

# returns array of all invite recipient ids
def gather_recipient_ids
  next_page = "offset=0"
  result = []

  while next_page != nil
    url = "/api/v1/invite_recipients?#{next_page}"
    response = @req.http_get(url)
    if ['200'].include?(response.code)
      body = JSON.parse(response.body)
      next_page = body.dig('metadata', 'next_page')
      body['data'].each { |recip| result << recip["id"] if recip["disabled_at"].nil? }
    else
      puts("ERROR: could not index invite recipients: #{response.body}")
      exit(1)
    end
  end
  result.uniq.compact
end

def disable_recipients(ids)
  return if ids.nil?

  response = @req.http_post("/api/v1/invite_recipients/disable", { hip_invite_recipient_ids: ids})
  unless ['200'].include?(response.code)
    puts("ERROR: could not disable invite_recipients: #{response.body}")
    exit(1)
  end
end

# ------------------- main ---------------------

ARGV << '-h' if ARGV.empty?

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: disable_invites.rb [config]"

  opts.on("-c [config_file]", "--config-file [config_file]", "Path to JSON config file") do |config|
    options['config'] = config
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

recipient_ids = gather_recipient_ids
puts("Found #{recipient_ids.count} invite recipients to disable.".green)
disable_recipients(recipient_ids)
puts("Done.".green)

exit(0)

