
#!/usr/bin/env ruby

# This script can be used to pull support bundles from Airwalls on a regular schedule
# The script expects a config file in JSON format that defines the Airwall UUIDs for which to get the bundles
# Example:
# {
#   "interval": "30m",
#   "rollover": "24h",
#   "download_path": "/tmp/bundles",
#   "airwall_ids": ["470fda7c-eb4f-4c0d-ad72-a4ad7ada4214", "6a359bef-bebd-46e3-9b70-dd61b016126a", "ac39b05f-21c0-4717-ac4b-98f4a3732933"],
#   "conductor_url": "conductor.acme.com",
#   "client_id": "loCkeaObuzP5Z2MR7XQWLw",
#   "api_token": "<secret-token>"
# }

require 'optparse'
require 'net/http'
require 'json'
require 'openssl'
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


# get the ids of all AWs associated with any of the ids/refs given
def gather_aw_info(config)
  aw_info = []
  config['airwall_ids'].each do |uuid|
    url = "/api/v1/hipservices/#{uuid}"
    response = @req.http_get(url)
    if response.code == '200'
      body = JSON.parse(response.body)
      aw_info << {
        uuid: uuid,
        endbox_uid: body['uid'],
        title: body['title']
      }
    else
      puts("ERROR: could not access Airwall info for ID #{uuid}: #{response.code} #{response.body}".red)
      exit(1)
    end
  end
  aw_info
end

def aw_job_save_diag(fname, response)
  File.open(fname, "w:ASCII-8BIT") do |file|
    file.puts(response.body)
  end
rescue => e
  puts e
  puts e.backtrace.first(10).join("\n")
  binding.pry
end

def title_name(info)
  if info[:title]
    "#{info[:title]} (#{info[:endbox_uid]})"
  else
    "#{info[:endbox_uid]}"
  end
end

# get the ids of only AWs that are active -- can only revoke if they are active
def get_support_bundles(aw_info)
  @time_requested = Time.now.getutc
  aw_info.each do |info|
    url = "/api/v1/hipservices/#{info[:uuid]}/support_bundle"
    puts "Requesting bundle for #{title_name(info)})"
    response = @req.http_post(url)
    if ['202'].include?(response.code)
      body = JSON.parse(response.body)
      # puts body.inspect
      job_id = body['job_id']
      info[:status_url] = "/api/v1/jobs/#{job_id}"
      info[:job_status] = 'progress'
    else
      puts("ERROR: could not get support bundle: #{response.code} #{response.body}".red)
      info[:job_status] = 'error'
    end
  end

  keep_going = true
  while keep_going do
    putc('.')
    keep_going = false
    aw_info.each do |info|
      if info[:job_status] == 'progress'
        response = @req.http_get(info[:status_url])
        body = JSON.parse(response.body)
        if body['status'] == 'progress'
          keep_going = true
        else
          info[:job_status] = body['status']
          info[:uri] = body['uri']
        end
      end
    end
    sleep 1 if keep_going
  end
  puts('')

  # download
  aw_info.each do |info|
    if info[:job_status] == 'complete'
      file_name = "#{@download_path}/#{@time_requested.strftime('%FT%T')}_#{info[:endbox_uid].gsub(/BHI@40130#/,'')}"
      url = "/api/v1/#{info[:uri]}"
      puts "downloading bundle to #{file_name}"
      response = @req.http_get(url)
      aw_job_save_diag(file_name, response)
    end
  end

  # handle rollovers
  Dir.each_child(@download_path) do |name|
    m = name.match(/^(\d\d\d\d)-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/)
    next unless m
    t = Time.new(m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i, m[5].to_i, m[6].to_i, "+00:00")
    if @time_requested - @rollover > t
      puts ("Removing bundle #{name}")
      FileUtils.rm_f("#{@download_path}/#{name}")
    end
  end

end

# Parse a duration string of the form 10s|5m|12h
def parse_duration(str)
  n = 60
  m = str.match(/\d+/)
  if m
    n = m[0].to_i
  end
  case str[-1]
  when 'm'
    n *= 60
  when 'h'
    n *= 3600
  end
  n
end
# ------------------- main ---------------------

ARGV << '-h' if ARGV.empty?

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: tnw_bundler.rb [config]"

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

airwall_ids = config_params['airwall_ids'] || []
if airwall_ids.empty?
  puts("ERROR: must provide at least one Airwall UUID in airwall_ids".red)
  exit(1)
end


@interval = parse_duration(config_params['interval'] || '10m')
if !@interval.is_a?(Integer) || @interval <= 0
  puts("ERROR: config param interval must be numeric".red)
  exit(1)
end

@rollover = parse_duration(config_params['rollover'] || '24h')
if !@rollover.is_a?(Integer) || @rollover <= 0
  puts("ERROR: config param rollover must be numeric".red)
  exit(1)
end

@download_path = config_params['download_path'] || '/tmp/bundles'
FileUtils.mkdir_p(@download_path)

puts("Will download bundles into #{@download_path}".green)

# initialize request object for API calls
headers = {
  'Content-Type' => 'application/json',
  'Accept' => 'application/json',
  'X-API-Client-ID' => client_id,
  'X-API-Token' => api_token
}
@req = Request.new(conductor, headers)

aw_ids = gather_aw_info(config_params)

while true do
  get_support_bundles(aw_ids)
  d = (Time.now - @time_requested).to_i

  if @interval > d
    puts "Will sleep for #{@interval - d} seconds"
    sleep(@interval - d)
  end
end

puts("Exiting.".green)

exit(0)