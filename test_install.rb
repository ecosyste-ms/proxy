require 'fileutils'
require 'open3'
require 'shellwords'
require 'tmpdir'
require 'test/unit'

class InstallCommandTest < Test::Unit::TestCase
  def setup
    @directory = Dir.mktmpdir('proxy-install-test')
    @page_dir = File.join(@directory, 'public & cache')
    @nginx_config = File.join(@directory, 'public-access.conf')
    @backup_dir = File.join(@directory, 'backups')
    @arguments = File.join(@directory, 'dokku-arguments')
    @config = File.join(@directory, 'settings.env')
    @settings = {
      'PROXY_APP' => 'test-cache', 'PROXY_PAGE_DIR' => @page_dir,
      'PROXY_NGINX_CONFIG' => @nginx_config, 'PROXY_BACKUP_DIR' => @backup_dir,
      'PROXY_FILE_OWNER' => Process.uid.to_s, 'PROXY_FILE_GROUP' => Process.gid.to_s
    }
    FileUtils.mkdir_p(@page_dir)
    File.write(File.join(@page_dir, 'index.html'), 'Previous homepage')
    File.write(@nginx_config, 'Previous routing')
    write_config
    File.write(File.join(@directory, 'dokku'), <<~SH)
      #!/bin/sh
      if [ "${INSTALL_TEST_FAIL:-0}" = 1 ] && [ ! -e "$INSTALL_TEST_ARGUMENTS" ]; then
        printf '%s\\n' "$@" >> "$INSTALL_TEST_ARGUMENTS"
        exit 1
      fi
      printf '%s\\n' "$@" >> "$INSTALL_TEST_ARGUMENTS"
    SH
    File.chmod(0755, File.join(@directory, 'dokku'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def write_config
    File.write(@config, @settings.map { |key, value| "#{key}=#{Shellwords.escape(value)}\n" }.join)
  end

  def run_command(fail_build: false, script: File.join(__dir__, 'install.sh'), config: @config)
    Open3.capture3(
      @settings.transform_values { nil }.merge(
        'PATH' => "#{@directory}:#{ENV.fetch('PATH')}", 'PROXY_CONFIG' => config,
        'INSTALL_TEST_ARGUMENTS' => @arguments, 'INSTALL_TEST_FAIL' => fail_build ? '1' : '0'
      ), 'sh', script, chdir: @directory
    )
  end

  def test_installs_homepage_and_renders_config_from_external_file
    output, error, status = run_command
    assert_predicate status, :success?, error
    assert_include output, 'Homepage installed.'
    assert_equal File.read(File.join(__dir__, 'public/index.html')), File.read(File.join(@page_dir, 'index.html'))
    assert_equal File.binread(File.join(__dir__, 'public/site-assets/social-share.png')),
                 File.binread(File.join(@page_dir, 'site-assets/social-share.png'))
    rendered = File.read(@nginx_config)
    assert_equal 2, rendered.scan("root \"#{@page_dir}\";").length
    assert_include rendered, 'try_files $uri =404;'
    assert_not_include rendered, '@PROXY_PAGE_DIR@'
    assert_equal %w[proxy:build-config test-cache], File.readlines(@arguments, chomp: true)
    backup = Dir.glob(File.join(@backup_dir, '*')).fetch(0)
    assert_equal 'Previous homepage', File.read(File.join(backup, 'public/index.html'))
    assert_equal 'Previous routing', File.read(File.join(backup, 'public-access.conf'))
  end

  def test_escapes_nginx_paths_and_preserves_nginx_variables
    special_dir = File.join(@directory, 'public "quoted" \\ & |')
    FileUtils.mv(@page_dir, special_dir)
    @settings['PROXY_PAGE_DIR'] = special_dir
    write_config
    _, error, status = run_command
    assert_predicate status, :success?, error
    escaped = special_dir.gsub(/[\\"]/) { |character| "\\#{character}" }
    assert_include File.read(@nginx_config), "root \"#{escaped}\";"
    assert_include File.read(@nginx_config), 'try_files $uri =404;'
  end

  def test_dollar_sign_in_page_path_fails_before_changing_files
    @settings['PROXY_PAGE_DIR'] = File.join(@directory, '$cache')
    write_config
    _, error, status = run_command
    assert_not_predicate status, :success?
    assert_include error, 'PROXY_PAGE_DIR cannot contain a dollar sign.'
    assert_equal 'Previous routing', File.read(@nginx_config)
    assert_false File.exist?(@backup_dir)
    assert_false File.exist?(@arguments)
  end

  def test_restores_previous_files_when_build_fails
    output, error, status = run_command(fail_build: true)
    assert_equal 1, status.exitstatus
    assert_empty output
    assert_include error, 'Installation failed. Restored the previous page and routing.'
    assert_equal 'Previous homepage', File.read(File.join(@page_dir, 'index.html'))
    assert_equal 'Previous routing', File.read(@nginx_config)
    assert_equal %w[proxy:build-config test-cache proxy:build-config test-cache], File.readlines(@arguments, chomp: true)
  end

  def test_missing_config_leaves_installation_untouched
    File.unlink(@config)
    _, error, status = run_command
    assert_not_predicate status, :success?
    assert_include error, 'Config file not found:'
    assert_equal 'Previous homepage', File.read(File.join(@page_dir, 'index.html'))
    assert_false File.exist?(@backup_dir)
    assert_false File.exist?(@arguments)
  end

  def test_incomplete_config_leaves_installation_untouched
    @settings.delete('PROXY_BACKUP_DIR')
    write_config
    _, error, status = run_command
    assert_not_predicate status, :success?
    assert_include error, 'Set PROXY_BACKUP_DIR'
    assert_equal 'Previous routing', File.read(@nginx_config)
    assert_false File.exist?(@backup_dir)
    assert_false File.exist?(@arguments)
  end

  def test_default_config_is_relative_to_script
    upload_dir = File.join(@directory, 'upload')
    FileUtils.mkdir_p(upload_dir)
    %w[install.sh nginx.conf public].each { |name| FileUtils.cp_r(File.join(__dir__, name), upload_dir) }
    FileUtils.cp(@config, File.join(upload_dir, 'config.env'))
    _, error, status = run_command(script: File.join(upload_dir, 'install.sh'), config: nil)
    assert_predicate status, :success?, error
    assert_include File.read(@nginx_config), "root \"#{@page_dir}\";"
  end
end
