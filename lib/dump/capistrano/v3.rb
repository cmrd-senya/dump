# encoding: UTF-8

require 'fileutils'
require 'shellwords'

require 'dump/continious_timeout'
require 'dump/env'

require 'active_support/core_ext/object/blank'

require 'English'

namespace :dump do
  def dump_command(command, env = {})
    rake = env.delete(:rake) || 'rake'

    # stringify_keys! from activesupport
    Dump::Env.stringify!(env)

    env.update(Dump::Env.for_command(command, true))

    cmd = %W[-s dump:#{command}]
    cmd += env.sort.map{ |key, value| "#{key}=#{value}" }
    "#{rake} #{cmd.shelljoin}"
  end

  def fetch_rails_env
    fetch(:rails_env, 'production')
  end

  def got_rsync?
    `which rsync`
    $CHILD_STATUS.success?
  end

  def with_additional_tags(*tags)
    tags = [tags, Dump::Env[:tags]].flatten.select(&:present?).join(',')
    Dump::Env.with_env(:tags => tags) do
      yield
    end
  end

  def print_and_return_or_fail
    out = yield
    fail 'Failed creating dump' if out.blank?
    print out
    out.strip
  end

  def run_local(cmd)
    `#{cmd}`
  end

  def run_remote(cmd)
    output = ''
    run(cmd) do |_channel, io, data|
      case io
      when :out
        output << data
      when :err
        $stderr << data
      end
    end
    output
  end
  
  def capture_local(rake_task, env = {})
    run_locally do
      with(env) do
        capture(:rake, "dump:#{rake_task}")
      end
    end
  end
  
  def capture_remote(rake_task, env = {})
    output = nil
    on primary(:db) do
      within current_path do
        with({ rails_env: fetch_rails_env, progress_tty: '+' }.merge(env)) do
          output = capture(:rake, "dump:#{rake_task}")
        end
      end
    end
    output
  end

  def last_part_of_last_line(out)
    line = out.strip.split(/\s*[\n\r]\s*/).last
    line.split("\t").last if line
  end

  def auto_backup?
    !Dump::Env.no?(:backup)
  end
  
  namespace :local do
    desc 'Create local dump' << Dump::Env.explain_variables_for_command(:create)
    task :create do
      print_and_return_or_fail do
        with_additional_tags('local') do
          capture_local(:create)
        end
      end
    end

    desc 'Restore local dump' << Dump::Env.explain_variables_for_command(:restore)
    task :restore do
      capture_local(:restore)
    end

    desc 'Versions of local dumps' << Dump::Env.explain_variables_for_command(:versions)
    task :versions do
      puts capture_local(:versions, show_size: true)
    end

    desc 'Cleanup local dumps' << Dump::Env.explain_variables_for_command(:cleanup)
    task :cleanup do
      puts capture_local(:cleanup)
    end

    desc 'Upload dump' << Dump::Env.explain_variables_for_command(:transfer)
    task :upload do
      file = Dump::Env.with_env(:summary => nil) do
        last_part_of_last_line(capture_local(:versions))
      end
      if file
        on primary(:db) do
          upload! "dump/#{file}", "#{current_path}/dump/#{file}"
        end
      end
    end
  end

  namespace :remote do
    desc 'Create remote dump' << Dump::Env.explain_variables_for_command(:create)
    task :create do
      print_and_return_or_fail do
        with_additional_tags('remote') do
          capture_remote(:create)
        end
      end
    end
    
    desc 'Restore remote dump' << Dump::Env.explain_variables_for_command(:restore)
    task :restore do
      capture_remote(:restore)
    end
    
    desc 'Versions of remote dumps' << Dump::Env.explain_variables_for_command(:versions)
    task :versions do
      puts capture_remote(:versions, show_size: true)
    end
    
    desc 'Cleanup of remote dumps' << Dump::Env.explain_variables_for_command(:cleanup)
    task :cleanup do
      puts capture_remote(:cleanup)
    end
    
    desc 'Download dump' << Dump::Env.explain_variables_for_command(:transfer)
    task :download do
      file = Dump::Env.with_env(:summary => nil) do
        last_part_of_last_line(capture_remote(:versions))
      end
      if file
        FileUtils.mkpath('dump')
        on primary(:db) do
          download! "#{current_path}/dump/#{file}", "dump/#{file}"
        end
      end
    end
  end
  
  desc 'Shorthand for dump:remote:create' << Dump::Env.explain_variables_for_command(:create)
  task :remote => "remote:create"
  
  desc 'Shorthand for dump:local:create' << Dump::Env.explain_variables_for_command(:create)
  task :default => "local:create"
  
  desc 'Shorthand for dump:local:upload' << Dump::Env.explain_variables_for_command(:transfer)
  task :upload => "local:upload"

  desc 'Shorthand for dump:remote:download' << Dump::Env.explain_variables_for_command(:transfer)
  task :download => "remote:download"
  
  namespace :mirror do
    desc 'Creates local dump, uploads and restores on remote' << Dump::Env.explain_variables_for_command(:mirror)
    task :up do
      auto_backup = if auto_backup?
        with_additional_tags('auto-backup') do
          invoke("dump:remote:create")
        end
      end
      if !auto_backup? || auto_backup.present?
        file = with_additional_tags('mirror') do
          capture_local(:create)
        end
        if file.present?
          Dump::Env.with_clean_env(:like => file) do
            invoke("dump:local:upload")
            invoke("dump:remote:restore")
          end
        end
      end
    end

    desc 'Creates remote dump, downloads and restores on local' << Dump::Env.explain_variables_for_command(:mirror)
    task :down do
      auto_backup = if auto_backup?
        with_additional_tags('auto-backup') do
          invoke("dump:local:create")
        end
      end
      if !auto_backup? || auto_backup.present?
        file = with_additional_tags('mirror') do
          capture_remote(:create)
        end
        if file.present?
          Dump::Env.with_clean_env(:like => file) do
            invoke("dump:remote:download")
            invoke("dump:local:restore")
          end
        end
      end
    end
  end
  
  namespace :backup do
    desc "Creates remote dump and downloads to local (desc defaults to 'backup')" << Dump::Env.explain_variables_for_command(:backup)
    task :create do
      file = with_additional_tags('backup') do
        capture_remote(:create)
      end
      if file.present?
        Dump::Env.with_clean_env(:like => file) do
          invoke("dump:remote:download")
        end
      end
    end

    desc 'Uploads dump with backup tag and restores it on remote' << Dump::Env.explain_variables_for_command(:backup_restore)
    task :restore do
      file = with_additional_tags('backup') do
        last_part_of_last_line(capture_local(:versions))
      end
      if file.present?
        Dump::Env.with_clean_env(:like => file) do
          invoke("dump:local:upload")
          invoke("dump:remote:restore")
        end
      end
    end
  end
  
  desc 'Shorthand for dump:backup:create' << Dump::Env.explain_variables_for_command(:backup)
  task :default => "backup:create"
  
  after 'deploy:updated', :create_dump_folder do
    from, to = %W[#{shared_path}/dump #{release_path}/dump]
    on primary(:db) do
      execute "mkdir -p #{from}; rm -rf #{to}; ln -s #{from} #{to}"
    end
  end
end
