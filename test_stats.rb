require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'test/unit'

class StatsCommandTest < Test::Unit::TestCase
  def setup
    @directory = Dir.mktmpdir('proxy-stats-test')
    @response = File.join(@directory, 'response.json')
    @arguments = File.join(@directory, 'ssh-arguments')
    @config = File.join(@directory, 'settings.env')
    File.write(@config, "PROXY_SSH_TARGET='operator@stats.example.com'\nPROXY_APP='test-cache'\n")
    File.write(File.join(@directory, 'ssh'), <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" > "$STATS_TEST_ARGUMENTS"
      cat "$STATS_TEST_RESPONSE"
      if [ "${STATS_TEST_EXIT:-0}" -ne 0 ]; then
        printf 'Connection refused\\n' >&2
      fi
      exit "${STATS_TEST_EXIT:-0}"
    SH
    File.chmod(0755, File.join(@directory, 'ssh'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def run_command(response, exit_code: 0)
    File.write(@response, response.is_a?(String) ? response : JSON.generate(response))
    Open3.capture3(
      { 'PATH' => "#{@directory}:#{ENV.fetch('PATH')}", 'STATS_TEST_RESPONSE' => @response,
        'STATS_TEST_ARGUMENTS' => @arguments, 'STATS_TEST_EXIT' => exit_code.to_s,
        'PROXY_CONFIG' => @config, 'PROXY_SSH_TARGET' => nil, 'PROXY_APP' => nil },
      RbConfig.ruby, Gem.bin_path('bundler', 'bundle'), 'exec', RbConfig.ruby,
      File.expand_path('stats.rb', __dir__), chdir: @directory
    )
  end

  def test_summary_through_stats_command
    output, error, status = run_command({
      'cached_artifacts' => 5, 'total_size_bytes' => 118_185,
      'downloads' => 1234, 'downloaded_bytes' => 2_097_152,
      'ecosystems' => [{ 'ecosystem' => 'npm', 'packages' => 2, 'versions' => 3,
                         'cached_artifacts' => 5, 'downloads' => 1234,
                         'cache_size_bytes' => 118_185, 'downloaded_bytes' => 2_097_152 }]
    })
    assert_predicate status, :success?, error
    assert_include output, 'Cached artifacts: 5'
    assert_include output, '115.4 KB'
    assert_include output, '1,234'
    assert_include output, '2.0 MB'
    assert_match(/npm\s+2\s+3\s+5\s+1,234/, output)
    arguments = File.readlines(@arguments, chomp: true)
    assert_include arguments, 'operator@stats.example.com'
    assert_equal %w[enter test-cache web wget -q -T 15 -O - http://127.0.0.1:8080/stats], arguments.last(10)
  end

  def test_relative_config_path
    @config = 'settings.env'
    output, error, status = run_command({ 'cached_artifacts' => 1, 'total_size_bytes' => 1024, 'stats_unavailable' => true })
    assert_predicate status, :success?, error
    assert_include output, 'Cached artifacts: 1'
  end

  def test_missing_config_fails_before_ssh
    File.unlink(@config)
    output, error, status = run_command({})
    assert_not_predicate status, :success?
    assert_empty output
    assert_include error, 'Config file not found:'
    assert_false File.exist?(@arguments)
  end

  def test_missing_target_fails_before_ssh
    File.write(@config, "PROXY_APP='test-cache'\n")
    output, error, status = run_command({})
    assert_not_predicate status, :success?
    assert_empty output
    assert_include error, 'Set PROXY_SSH_TARGET'
    assert_false File.exist?(@arguments)
  end

  def test_default_config_is_relative_to_script
    FileUtils.cp(File.join(__dir__, 'stats.rb'), @directory)
    FileUtils.cp(@config, File.join(@directory, 'config.env'))
    File.write(@response, JSON.generate({ 'cached_artifacts' => 1, 'total_size_bytes' => 1024, 'stats_unavailable' => true }))
    output, error, status = Open3.capture3(
      { 'PATH' => "#{@directory}:#{ENV.fetch('PATH')}", 'STATS_TEST_RESPONSE' => @response,
        'STATS_TEST_ARGUMENTS' => @arguments, 'PROXY_CONFIG' => nil,
        'PROXY_SSH_TARGET' => nil, 'PROXY_APP' => nil },
      RbConfig.ruby, Gem.bin_path('bundler', 'bundle'), 'exec', RbConfig.ruby,
      File.join(@directory, 'stats.rb'), chdir: '/'
    )
    assert_predicate status, :success?, error
    assert_include output, 'Cached artifacts: 1'
    assert_include File.read(@arguments), 'operator@stats.example.com'
  end

  def test_empty_app_fails_before_ssh
    File.write(@config, "PROXY_SSH_TARGET='operator@stats.example.com'\nPROXY_APP=''\n")
    output, error, status = run_command({})
    assert_not_predicate status, :success?
    assert_empty output
    assert_include error, 'Set PROXY_APP'
    assert_false File.exist?(@arguments)
  end

  def test_unavailable_breakdown_is_not_reported_as_zero_hits
    output, error, status = run_command({ 'cached_artifacts' => 5, 'total_size_bytes' => 118_185, 'stats_unavailable' => true })
    assert_predicate status, :success?, error
    assert_include output, 'Cached artifacts: 5'
    assert_include output, 'unavailable'
    assert_not_include output, 'Cache hits:'
  end

  def test_failed_ssh_does_not_print_a_summary
    output, error, status = run_command('', exit_code: 255)
    assert_equal 255, status.exitstatus
    assert_empty output
    assert_include error, 'Connection refused'
  end

  def test_invalid_response_fails_clearly
    output, error, status = run_command('not JSON')
    assert_not_predicate status, :success?
    assert_empty output
    assert_include error, 'Invalid proxy stats response'
  end
end
