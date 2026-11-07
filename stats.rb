require 'dotenv'
require 'json'
require 'open3'

def bytes(value)
  amount = Integer(value).to_f
  units = %w[B KB MB GB TB]
  unit = units.shift
  while amount >= 1024 && !units.empty?
    amount /= 1024
    unit = units.shift
  end
  unit == 'B' ? "#{amount.to_i} B" : format('%.1f %s', amount, unit)
end

def count(value)
  Integer(value).to_s.reverse.scan(/.{1,3}/).join(',').reverse
end

abort 'Usage: bundle exec ruby stats.rb' unless ARGV.empty?

config_path = ENV.fetch('PROXY_CONFIG', File.join(__dir__, 'config.env'))
unless File.file?(config_path) && File.readable?(config_path)
  abort "Config file not found: #{config_path} (copy config.env.example or set PROXY_CONFIG)"
end
Dotenv.load(config_path, overwrite: true)
%w[PROXY_SSH_TARGET PROXY_APP].each do |key|
  abort "Set #{key} in #{config_path}" if ENV[key].to_s.empty?
end

output, error, status = Open3.capture3(
  'ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
  '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2',
  ENV.fetch('PROXY_SSH_TARGET'), 'enter', ENV.fetch('PROXY_APP'), 'web',
  'wget', '-q', '-T', '15', '-O', '-', 'http://127.0.0.1:8080/stats'
)
unless status.success?
  warn "Could not read proxy stats over SSH: #{error.strip}"
  exit(status.exitstatus || 1)
end

begin
  stats = JSON.parse(output)
  artifacts = count(stats.fetch('cached_artifacts'))
  size = bytes(stats.fetch('total_size_bytes'))
  unavailable = stats['stats_unavailable']
  rows = unless unavailable
    stats.fetch('ecosystems').sort_by { |entry| -Integer(entry.fetch('downloaded_bytes')) }.map do |entry|
      [entry.fetch('ecosystem'), count(entry.fetch('packages')), count(entry.fetch('versions')),
       count(entry.fetch('cached_artifacts')), count(entry.fetch('downloads')),
       bytes(entry.fetch('cache_size_bytes')), bytes(entry.fetch('downloaded_bytes'))]
    end
  end
  hits = count(stats.fetch('downloads')) unless unavailable
  served = bytes(stats.fetch('downloaded_bytes')) unless unavailable
rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
  abort "Invalid proxy stats response: #{error.message}"
end

puts 'proxy.ecosyste.ms'
puts "Cached artifacts: #{artifacts}"
puts "Cache size:       #{size}"
if unavailable
  puts 'Cache hit figures and ecosystem breakdown are unavailable.'
  exit
end
puts "Cache hits:       #{hits}"
puts "Served from cache: #{served}"

unless rows.empty?
  headers = ['Ecosystem', 'Packages', 'Versions', 'Artifacts', 'Hits', 'Cache', 'Served']
  widths = headers.each_index.map { |index| ([headers] + rows).map { |row| row[index].length }.max }
  puts
  ([headers] + rows).each do |row|
    puts row.each_with_index.map { |value, index| index.zero? ? value.ljust(widths[index]) : value.rjust(widths[index]) }.join('  ')
  end
end
puts
puts 'Hit counts and served bytes cover artifacts currently in the cache.'
