require "delegate"

class Hookup
  class PostCheckout

    attr_reader :old_sha, :new_sha, :env

    def partial?
      @partial
    end

    def schema_dir
      File.join(working_dir, env['HOOKUP_SCHEMA_DIR'])
    end

    def possible_schemas
      %w(development_structure.sql schema.rb structure.sql).map do |file|
        File.join schema_dir, file
      end
    end

    def working_dir
      env['HOOKUP_WORKING_DIR'] || '.'
    end

    def initialize(environment, *args)
      @env ||= environment.to_hash.dup
      require 'optparse'
      opts = OptionParser.new
      opts.banner = "Usage: hookup post-checkout <old> <new> <full>"
      opts.on('-Cdirectory', 'cd to directory') do |directory|
        env['HOOKUP_WORKING_DIR'] = directory
      end
      opts.on('--schema-dir=DIRECTORY', 'Path to DIRECTORY containing schema.rb and migrate/') do |directory|
        env['HOOKUP_SCHEMA_DIR'] = directory
      end
      opts.on('--load-schema=COMMAND', 'Run COMMAND on migration failure') do |command|
        env['HOOKUP_LOAD_SCHEMA'] = command
      end
      opts.parse!(args)

      @old_sha = args.shift
      if @old_sha == '0000000000000000000000000000000000000000'
        @old_sha = EMPTY_DIR
      elsif @old_sha.nil?
        @old_sha = '@{-1}'
      end
      @new_sha = args.shift || 'HEAD'
      @partial = (args.shift == '0')

      env['HOOKUP_SCHEMA_DIR'] = 'db' unless env['HOOKUP_SCHEMA_DIR'] && File.directory?(schema_dir)
    end

    def run
      return if skipped? || env['GIT_REFLOG_ACTION'] =~ /^(?:pull|rebase)/
      unless partial?
        bundle
        migrate
      end
    end

    def bundler?
      File.exist?('Gemfile')
    end

    def bundle
      return unless bundler?
      if changes.grep(/^Gemfile|\.gemspec$/).any?
        begin
          # If Bundler in turn spawns Git, it can get confused by $GIT_DIR
          git_dir = ENV.delete('GIT_DIR')
          unless system("bundle check")
            Dir.chdir(working_dir) do
              system("bundle | grep -v '^Using ' | grep -v ' is complete'")
            end
          end
        ensure
          ENV['GIT_DIR'] = git_dir
        end
      end
    end

    def migrate
      schemas = possible_schemas.select do |schema|
        change = changes[schema]
        rake 'db:create' if change && change.added?
        change && !change.deleted?
      end

      return if schemas.empty?

      migrations = changes.grep(/^#{schema_dir}\/migrate/)
      begin
        migrations.select { |migration| migration.deleted? || migration.modified? }.reverse.each do |migration|
          file = migration.file
          begin
            system 'git', 'checkout', old_sha, '--', file
            unless rake 'db:migrate:down', "VERSION=#{File.basename(file)}"
              raise Error, "Failed to rollback #{File.basename(file)}"
            end
          ensure
            if migration.deleted?
              system 'git', 'rm', '--force', '--quiet', '--', file
            else
              system 'git', 'checkout', new_sha, '--', file
            end
          end
        end

        if migrations.any? { |migration| migration.added? || migration.modified? }
          rake 'db:migrate'
        end

      ensure
        _changes = x("git diff --name-status #{new_sha} -- #{schemas.join(' ')}")

        unless _changes.empty?
          system 'git', 'checkout', '--', *schemas

          puts "Schema out of sync."

          fallback = env['HOOKUP_LOAD_SCHEMA']
          if fallback && fallback != ''
            puts "Trying #{fallback}..."
            system fallback
          end
        end
      end
    end

    def rake(*args)
      Dir.chdir(working_dir) do
        if File.executable?('bin/rake')
          system 'bin/rake', *args
        elsif bundler?
          system 'bundle', 'exec', 'rake', *args
        else
          system 'rake', *args
        end
      end
    end

    def skipped?
      env['SKIP_HOOKUP']
    end

    def system(*args)
      puts "\e[90m[#{File.basename Dir.pwd}] #{args.join(" ")}\e[0m"
      super
    end

    def x(command)
      puts "\e[90m[#{File.basename Dir.pwd}] #{command}\e[0m"
      %x{#{command}}
    end

    def changes
      @changes ||= DiffChanges.new((old_sha != new_sha) && x("git diff --name-status #{old_sha} #{new_sha}"))
    end

    class DiffChange < Struct.new(:type, :file)
      def added?
        type == "A"
      end

      def copied?
        type == "C"
      end

      def deleted?
        type == "D"
      end

      def modified?
        type == "M"
      end

      def renamed?
        type == "R"
      end

      def type_changed?
        type == "T"
      end

      def unmerged?
        type == "U"
      end

      def broken?
        type == "B"
      end
    end

    class DiffChanges < SimpleDelegator
      def initialize(diff)
        super diff.to_s.scan(/^([^\t]+)\t(.*)$/).map { |(type, file)| DiffChange.new(type, file) }
      end

      def grep(regex)
        __getobj__.select { |change| change.file =~ regex }
      end

      def [](filename)
        __getobj__.detect { |change| change.file == filename }
      end
    end

  end
end
