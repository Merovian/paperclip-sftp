module Paperclip
  module Storage
    # SFTP (Secure File Transfer Protocol) storage for Paperclip.
    #
    module Sftp

      # SFTP storage expects a hash with following options:
      # :host, :user, :fs_root, :options.
      #
      def self.extended(base)
        begin
          require "net/sftp"
        rescue LoadError => e
          e.message << "(You may need to install net-sftp gem)"
          raise e
        end unless defined?(Net::SFTP)

        base.instance_exec do
          @sftp_options = options[:sftp_options] || {}
          @sftp_options[:fs_root] = '/' unless @sftp_options[:fs_root]
          @sftp_options[:options] = {} if @sftp_options[:options].nil?

          unless @options[:url].to_s.match(/^:sftp.*url$/)
            @options[:path] = @options[:path].gsub(/:url/, @options[:url])
            @options[:url] = ':sftp_public_url'
          end

          Paperclip.interpolates(:sftp_public_url) do |attachment, style|
            attachment.public_url(style)
          end unless Paperclip::Interpolations.respond_to? :sftp_public_url
        end
      end

      def public_url(style=default_style)
        if @options[:sftp_host]
          "#{dynamic_sftp_host_for_style(style)}/#{remote_directory(path(style))}"
        else
          "/#{path(style)}"
        end
      end

      def dynamic_sftp_host_for_style(style)
        if @options[:sftp_host].respond_to?(:call)
          @options[:sftp_host].call(self)
        else
          "/#{path(style)}"
        end
      end

      # Make SFTP connection, but use current one if exists.
      #
      def sftp
        @sftp ||= obtain_net_sftp_instance_for(@sftp_options)
      end

      def obtain_net_sftp_instance_for(options)
        instances = (Thread.current[:paperclip_sftp_instances] ||= {})
        instances[options] ||= Net::SFTP.start(
          options[:host],
          options[:user],
          options[:options]
        )
      end

      def exists?(style = default_style)
        if original_filename
          files = sftp.dir.entries(File.dirname(@sftp_options[:fs_root]+path(style))).map(&:name)
          files.include?(File.basename(path(style)))
        else
          false
        end
      rescue Net::SFTP::StatusException => e
        false
      end

      def copy_to_local_file(style, local_dest_path)
        log("copying #{remote_directory(path(style))} to local file #{local_dest_path}")
        sftp.download!(@sftp_options[:fs_root]+remote_directory(path(style)), local_dest_path)
      rescue Net::SFTP::StatusException => e
        warn("#{e} - cannot copy #{remote_directory(path(style))} to local file #{local_dest_path}")
        false
      end

      def flush_writes #:nodoc:
        @queued_for_write.each do |style, file|
          mkdir_p(File.dirname(path(style)))
          log("uploading #{file.path} to #{remote_directory(path(style))}")
          sftp.upload!(file.path, @sftp_options[:fs_root]+remote_directory(path(style)))
          sftp.setstat!(@sftp_options[:fs_root]+remote_directory(path(style)), :permissions => 0644)
        end

        after_flush_writes # allows attachment to clean up temp files
        @queued_for_write = {}
      end

      def flush_deletes #:nodoc:
        @queued_for_delete.each do |path|
          begin
            log("deleting file #{path}")
            sftp.remove(@sftp_options[:fs_root]+remote_directory(path)).wait
          rescue Net::SFTP::StatusException => e
            # ignore file-not-found, let everything else pass
          end

          begin
            path = File.dirname(@sftp_options[:fs_root]+remote_directory(path))
            while sftp.dir.entries(remote_directory(path)).delete_if { |e| e.name =~ /^\./ }.empty?
              sftp.rmdir(remote_directory(path)).wait
              path = File.dirname(remote_directory(path))
            end
          rescue Net::SFTP::StatusException => e
            # stop trying to remove parent directories
          end
        end

        @queued_for_delete = []
      end

      private

      # Create directory structure.
      #
      def mkdir_p(remote_dir)
        remote_path = remote_directory(remote_dir)
        log("mkdir_p for #{remote_path}")
        root_directory = @sftp_options[:fs_root] + '/'
        remote_path.split('/').each do |directory|
          next if directory.blank?
          unless sftp.dir.entries(root_directory).map(&:name).include?(directory)
            sftp.mkdir!("#{root_directory}#{directory}")
          end
          root_directory += "#{directory}/"
        end
      end

      def remote_directory(directory)
        return directory.gsub(/^.*public/, "\/public") 
      end

    end
  end
end
