#!/usr/bin/env ruby

# This script accepts a config with lists of tag references, overlay_network_ids, airwall_group_ids and/or airwall_ids
# and revokes then deletes any airwalls that are associated with those objects

require 'optparse'
require 'net/http'
require 'json'
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

def get_ovl_aw_ids(ovl_ids)
  ovl_ids = [ovl_ids].flatten

  res = []
  ovl_ids.each do |ovl_id|
    response = @req.http_get("/api/v1/overlay_networks/#{ovl_id}")
    if ['200'].include?(response.code)
      body = JSON.parse(response.body)
      res.concat(body['hipservices'])
    else
      puts("WARNING: could not get Airwalls for overlay #{ovl_id}: #{response.code} #{response.body}".yellow)
    end
  end
 
  res
end


def get_hsg_aw_ids(hsg_ids)
  hsg_ids = [hsg_ids].flatten

  res = []
  hsg_ids.each do |hsg_id|
    response = @req.http_get("/api/v1/hipservice_groups/#{hsg_id}")
    if ['200'].include?(response.code)
      body = JSON.parse(response.body)
      res.concat(body['hipservices_ids'])
    else
      puts("WARNING: could not get Airwalls for Airwall group #{hsg_id}: #{response.code} #{response.body}".yellow)
    end
  end
 
  res
end

def get_tag_aw_ids(tag_refs)
  tag_refs = [tag_refs].flatten

  res = []
  tag_refs.each do |tag_ref|
    response = @req.http_get("/api/v1/tags/#{tag_ref}/hipservices")
    if ['200'].include?(response.code)
      body = JSON.parse(response.body)
      res.concat(body.map{ |hs|  hs['id'] })
    else
      puts("WARNING: could not get tagged Airwalls for tag #{tag_ref}: #{response.code} #{response.body}".yellow)
    end
  end
 
  res
end

# get the ids of all AWs associated with any of the ids/refs given
def gather_aw_ids(config)
  aw_ids = []
  aw_ids.concat(config['airwall_ids']) unless config['airwall_ids'].nil?
  aw_ids.concat(get_ovl_aw_ids(config['overlay_network_ids'])) unless config['overlay_network_ids'].nil?
  aw_ids.concat(get_hsg_aw_ids(config['airwall_group_ids'])) unless config['airwall_group_ids'].nil?
  aw_ids.concat(get_tag_aw_ids(config['tag_refs'])) unless config['tag_refs'].nil?
  aw_ids
end

# get the ids of only AWs that are active -- can only revoke if they are active
def find_active(aw_ids)
  res = []

  unless aw_ids.empty?
    next_page = "offset=0"

    while next_page != nil
      url = "/api/v1/hipservices?filter=active::true&#{next_page}"
      response = @req.http_get(url)
      if ['200'].include?(response.code)
        body = JSON.parse(response.body)
        next_page = body.dig('metadata', 'next_page')
        body['data'].each{ |hs| res << hs['id'] if aw_ids.include?(hs['id']) && hs['active'] }
      else
        puts("ERROR: could not get list of active Airwalls: #{response.code} #{response.body}".red)
        exit(1)
      end
    end
  end

  res
end

def revoke_aws(aw_ids)
  return if aw_ids.empty?

  puts("Revoking #{aw_ids.count} active Airwalls".green)

  data = {
      hipservice_ids: aw_ids.uniq,
  }

  url = "/api/v1/hipservices/revoke"
  response = @req.http_post(url, data)
  unless ['200'].include?(response.code)
    puts("ERROR: could not revoke Airwalls: #{response.code} #{response.body}".red)
    exit(1)
  end
end

def delete_aws(aw_ids)
  return if aw_ids.empty?

  puts("Deleteing #{aw_ids.count} Airwalls".green)

  data = {
      hipservice_ids: aw_ids.uniq,
  }

  url = "/api/v1/hipservices"
  response = @req.http_delete(url, data)
  unless ['200'].include?(response.code)
    puts("ERROR: could not delete Airwalls: #{response.code} #{response.body}".red)
    exit(1)
  end
end

# ------------------- main ---------------------

ARGV << '-h' if ARGV.empty?

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: revoke_and_delete.rb [config]"

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

aw_ids = gather_aw_ids(config_params).uniq
puts("Found #{aw_ids.count} Airwall IDs to remove".green)

active_aw_ids = find_active(aw_ids)
revoke_aws(active_aw_ids) # only try to revoke active airwalls
delete_aws(aw_ids)

puts("Done.".green)

exit(0)
