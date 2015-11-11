# -*- encoding: utf-8 -*-

module Aliyun
  module OSS
    module Multipart

      PART_SIZE = 1024 * 1024
      READ_SIZE = 16 * 1024

      ##
      # A multipart download transaction
      #
      class Download < Transaction
        def initialize(opts)
          super(opts)
          @file, @checkpoint_file = opts[:file], opts[:resume_token]
          @object_meta = {}
          @parts = []
        end

        def run
          logger.info("Begin download, file: #{@file}, checkpoint file: #{@checkpoint_file}")

          rebuild!

          divide_parts! if @parts.empty?

          @parts.reject {|p| p[:done]}.each do |p|
            download_part!(p)
          end

          commit!

          logger.info("Done download, file: #{@file}")
        end

        # Checkpoint structures:
        # status = {
        #   :id => 'download_id',
        #   :file => 'file',
        #   :object_meta => {
        #     :etag => 'xxx',
        #     :size => 1024
        #   },
        #   :parts => [
        #     {:number => 1, :range => [0, 100], :md5 => 'xxx', :done => false},
        #     {:number => 2, :range => [100, 200], :md5 => 'yyy', :done => true}
        #   ]
        # }
        def checkpoint!
          logger.info("Begin make checkpoint")

          ensure_object_not_changed

          status = {
            :id => id,
            :file => @file,
            :object_meta => @object_meta,
            :parts => @parts
          }

          status[:md5] = Util.get_content_md5(status.to_json)

          File.open(@checkpoint_file, 'w') do |f|
            f.write(status.to_json)
          end

          logger.info("Done make checkpoint, status: #{status}")
        end

        private
        # Commit the transaction when all parts are succefully uploaded
        # @todo handle undefined behaviors: commit succeeds in server
        #  but return error in client
        def commit!
          logger.info("Begin commit transaction, id: #{id}")

          # concat all part files into the target file
          File.open(@file, 'w') do |w|
            @parts.sort{ |x, y| x[:number] <=> y[:number] }.each do |p|
              File.open(get_part_file(p[:number])) do |r|
                  w.write(r.read(READ_SIZE)) until r.eof?
              end
            end
          end

          File.delete(@checkpoint_file)
          @parts.each{ |p| File.delete(get_part_file(p[:number])) }

          logger.info("Done commit transaction, id: #{id}")
        end

        # Rebuild the status of the transaction from token file
        def rebuild!
          logger.info("Begin rebuild transaction, checkpoint: #{@checkpoint_file}")

          if File.exists?(@checkpoint_file)
            status = load_checkpoint
            md5 = status.delete(:md5)
            raise TokenInconsistentError.new("The resume token is changed.") \
                    if md5 != Util.get_content_md5(status.to_json)

            status[:parts].select{ |p| p[:done] }.each do |p|
              part_file = get_part_file(p[:number])
              raise PartMissingError.new("The part file is missing.") \
                                        unless File.exist?(part_file)
              raise FileInconsistentError.new("The part file is changed.") \
                                        if p[:md5] != Digest::MD5.file(part_file).to_s
            end
            @id = status[:id]
            @object_meta = status[:object_meta]
            @parts = status[:parts]
          else
            initiate!
          end

          logger.info("Done rebuild transaction, status: #{status}")
        end

        def initiate!
          logger.info("Begin initiate transaction")

          @id = generate_download_id
          obj = Protocol.get_object_meta(bucket, object)
          @object_meta = {
            :etag => obj.etag,
            :size => obj.size
          }
          checkpoint!

          logger.info("Done initiate transaction, id: #{id}")
        end

        # Download a part
        def download_part!(p)
          logger.info("Begin download part: #{p}")

          part_file = get_part_file(p[:number])
          File.open(part_file, 'w') do |w|
            Protocol.get_object(bucket, object, :range => p[:range]) do |chunk|
              w.write(chunk)
            end
          end

          p[:done] = true
          p[:md5] = Digest::MD5::file(part_file).to_s

          checkpoint!

          logger.info("Done download part: #{p}")
        end

        # Devide the object to download into parts to download
        def divide_parts!
          logger.info("Begin divide parts, object: #{@object}")

          object_size = @object_meta[:size]
          part_size = @options[:part_size] || PART_SIZE
          num_parts = (object_size - 1) / part_size + 1
          @parts = (1..num_parts).map do |i|
            {
              :number => i,
              :range => [(i-1) * part_size, [i * part_size, object_size].min],
              :done => false
            }
          end

          checkpoint!

          logger.info("Done divide parts, parts: #{@parts}")
        end

        # Ensure file not changed during uploading
        def ensure_object_not_changed
          obj = Protocol.get_object_meta(bucket, object)
          raise ObjectInconsistentError.new("The object to download is changed.") \
                                           unless obj.etag == @object_meta[:etag]

        end

        # Load transaction states from checkpoint file
        def load_checkpoint
          status = JSON.load(File.read(@checkpoint_file))
          status.symbolize_keys!
          status
        end

        # Generate a download id
        def generate_download_id
          "download_#{bucket}_#{object}_#{Time.now.to_i}"
        end

        # Get part file
        def get_part_file(number)
          "#{@file}.part.#{number}"
        end
      end # Download

    end # Multipart
  end # OSS
end # Aliyun