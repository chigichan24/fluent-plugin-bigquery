# -*- coding: utf-8 -*-

require 'fluent/plugin/bigquery/version'

require 'fluent/mixin/config_placeholders'
require 'fluent/mixin/plaintextformatter'

require 'fluent/plugin/bigquery/schema'

## TODO: load implementation
# require 'fluent/plugin/bigquery/load_request_body_wrapper'

module Fluent
  ### TODO: error classes for each api error responses
  # class BigQueryAPIError < StandardError
  # end

  class BigQueryOutput < TimeSlicedOutput
    Fluent::Plugin.register_output('bigquery', self)

    # https://developers.google.com/bigquery/browser-tool-quickstart
    # https://developers.google.com/bigquery/bigquery-api-quickstart

    ### default for insert
    def configure_for_insert(conf)
      raise ConfigError unless conf["method"] != "load"

      conf["buffer_type"]                = "lightening"  unless conf["buffer_type"]
      conf["flush_interval"]             = 0.25          unless conf["flush_interval"]
      conf["try_flush_interval"]         = 0.05          unless conf["try_flush_interval"]
      conf["buffer_chunk_limit"]         = 1 * 1024 ** 2 unless conf["buffer_chunk_limit"] # 1MB
      conf["buffer_queue_limit"]         = 1024          unless conf["buffer_queue_limit"]
      conf["buffer_chunk_records_limit"] = 500           unless conf["buffer_chunk_records_limit"]
    end

    ### default for loads
    def configure_for_load(conf)
      raise ConfigError unless conf["method"] == "load"

      # buffer_type, flush_interval, try_flush_interval is TimeSlicedOutput default
      conf["buffer_chunk_limit"] = 1 * 1024 ** 3 unless conf["buffer_chunk_limit"] # 1GB
      conf["buffer_queue_limit"] = 32            unless conf["buffer_queue_limit"]
    end

    ### for loads
    ### TODO: different default values for buffering between 'load' and insert
    # config_set_default :flush_interval, 1800 # 30min => 48 imports/day
    # config_set_default :buffer_chunk_limit, 1000**4 # 1.0*10^12 < 1TB (1024^4)

    ### OAuth credential
    # config_param :client_id, :string
    # config_param :client_secret, :string

    # Available methods are:
    # * private_key -- Use service account credential from pkcs12 private key file
    # * compute_engine -- Use access token available in instances of ComputeEngine
    # * private_json_key -- Use service account credential from JSON key
    # * application_default -- Use application default credential
    config_param :auth_method, :string, default: 'private_key'

    ### Service Account credential
    config_param :email, :string, default: nil
    config_param :private_key_path, :string, default: nil
    config_param :private_key_passphrase, :string, default: 'notasecret', secret: true
    config_param :json_key, default: nil

    # see as simple reference
    #   https://github.com/abronte/BigQuery/blob/master/lib/bigquery.rb
    config_param :project, :string

    # dataset_name
    #   The name can be up to 1,024 characters long, and consist of A-Z, a-z, 0-9, and the underscore,
    #   but it cannot start with a number or underscore, or have spaces.
    config_param :dataset, :string

    # table_id
    #   In Table ID, enter a name for your new table. Naming rules are the same as for your dataset.
    config_param :table, :string, default: nil
    config_param :tables, :string, default: nil
    config_param :template_suffix, :string, default: nil

    config_param :auto_create_table, :bool, default: false

    # skip_invalid_rows (only insert)
    #   Insert all valid rows of a request, even if invalid rows exist.
    #   The default value is false, which causes the entire request to fail if any invalid rows exist.
    config_param :skip_invalid_rows, :bool, default: false
    # max_bad_records (only load)
    #   The maximum number of bad records that BigQuery can ignore when running the job.
    #   If the number of bad records exceeds this value, an invalid error is returned in the job result.
    #   The default value is 0, which requires that all records are valid.
    config_param :max_bad_records, :integer, default: 0
    # ignore_unknown_values
    #   Accept rows that contain values that do not match the schema. The unknown values are ignored.
    #   Default is false, which treats unknown values as errors.
    config_param :ignore_unknown_values, :bool, default: false

    config_param :schema_path, :string, default: nil
    config_param :fetch_schema, :bool, default: false
    config_param :schema_cache_expire, :time, default: 600
    config_param :field_string,  :string, default: nil
    config_param :field_integer, :string, default: nil
    config_param :field_float,   :string, default: nil
    config_param :field_boolean, :string, default: nil
    config_param :field_timestamp, :string, default: nil
    ### TODO: record field stream inserts doesn't works well?
    ###  At table creation, table type json + field type record -> field type validation fails
    ###  At streaming inserts, schema cannot be specified
    # config_param :field_record,  :string, defualt: nil
    # config_param :optional_data_field, :string, default: nil

    REGEXP_MAX_NUM = 10
    config_param :replace_record_key, :bool, default: false
    (1..REGEXP_MAX_NUM).each {|i| config_param :"replace_record_key_regexp#{i}", :string, default: nil }

    config_param :convert_hash_to_json, :bool, default: false

    config_param :time_format, :string, default: nil
    config_param :localtime, :bool, default: nil
    config_param :utc, :bool, default: nil
    config_param :time_field, :string, default: nil

    # insert_id_field (only insert)
    config_param :insert_id_field, :string, default: nil
    # prevent_duplicate_load (only load)
    config_param :prevent_duplicate_load, :bool, default: false

    config_param :method, :string, default: 'insert' # or 'load'

    config_param :load_size_limit, :integer, default: 1000**4 # < 1TB (1024^4) # TODO: not implemented now
    ### method: 'load'
    #   https://developers.google.com/bigquery/loading-data-into-bigquery
    # Maximum File Sizes:
    # File Type   Compressed   Uncompressed
    # CSV         1 GB         With new-lines in strings: 4 GB
    #                          Without new-lines in strings: 1 TB
    # JSON        1 GB         1 TB

    config_param :row_size_limit, :integer, default: 100*1000 # < 100KB # configurable in google ?
    # config_param :insert_size_limit, :integer, default: 1000**2 # < 1MB
    # config_param :rows_per_second_limit, :integer, default: 1000 # spike limit
    ### method: ''Streaming data inserts support
    #  https://developers.google.com/bigquery/streaming-data-into-bigquery#usecases
    # Maximum row size: 100 KB
    # Maximum data size of all rows, per insert: 1 MB
    # Maximum rows per second: 100 rows per second, per table, with allowed and occasional bursts of up to 1,000 rows per second.
    #                          If you exceed 100 rows per second for an extended period of time, throttling might occur.
    ### Toooooooooooooo short/small per inserts and row!

    ## Timeout
    # request_timeout_sec
    #   Bigquery API response timeout
    # request_open_timeout_sec
    #   Bigquery API connection, and request timeout
    config_param :request_timeout_sec, :time, default: nil
    config_param :request_open_timeout_sec, :time, default: 60

    ### Table types
    # https://developers.google.com/bigquery/docs/tables
    #
    # type - The following data types are supported; see Data Formats for details on each data type:
    # STRING
    # INTEGER
    # FLOAT
    # BOOLEAN
    # RECORD A JSON object, used when importing nested records. This type is only available when using JSON source files.
    #
    # mode - Whether a field can be null. The following values are supported:
    # NULLABLE - The cell can be null.
    # REQUIRED - The cell cannot be null.
    # REPEATED - Zero or more repeated simple or nested subfields. This mode is only supported when using JSON source files.

    RETRYABLE_ERROR_REASON = %w(backendError internalError rateLimitExceeded tableUnavailable).freeze

    def initialize
      super
      require 'multi_json'
      require 'google/apis/bigquery_v2'
      require 'googleauth'
      require 'active_support/json'
      require 'active_support/core_ext/hash'
      require 'active_support/core_ext/object/json'

      # MEMO: signet-0.6.1 depend on Farady.default_connection
      Faraday.default_connection.options.timeout = 60
    end

    # Define `log` method for v0.10.42 or earlier
    unless method_defined?(:log)
      define_method("log") { $log }
    end

    def configure(conf)
      if conf["method"] == "load"
        configure_for_load(conf)
      else
        configure_for_insert(conf)
      end
      super

      if @method == "insert"
        extend(InsertImplementation)
      elsif @method == "load"
        extend(LoadImplementation)
      else
        raise Fluent::ConfigError "'method' must be 'insert' or 'load'"
      end

      case @auth_method
      when 'private_key'
        unless @email && @private_key_path
          raise Fluent::ConfigError, "'email' and 'private_key_path' must be specified if auth_method == 'private_key'"
        end
      when 'compute_engine'
        # Do nothing
      when 'json_key'
        unless @json_key
          raise Fluent::ConfigError, "'json_key' must be specified if auth_method == 'json_key'"
        end
      when 'application_default'
        # Do nothing
      else
        raise Fluent::ConfigError, "unrecognized 'auth_method': #{@auth_method}"
      end

      unless @table.nil? ^ @tables.nil?
        raise Fluent::ConfigError, "'table' or 'tables' must be specified, and both are invalid"
      end

      @tablelist = @tables ? @tables.split(',') : [@table]

      @fields = Fluent::BigQuery::RecordSchema.new('record')
      if @schema_path
        @fields.load_schema(MultiJson.load(File.read(@schema_path)))
      end

      types = %w(string integer float boolean timestamp)
      types.each do |type|
        raw_fields = instance_variable_get("@field_#{type}")
        next unless raw_fields
        raw_fields.split(',').each do |field|
          @fields.register_field field.strip, type.to_sym
        end
      end

      @regexps = {}
      (1..REGEXP_MAX_NUM).each do |i|
        next unless conf["replace_record_key_regexp#{i}"]
        regexp, replacement = conf["replace_record_key_regexp#{i}"].split(/ /, 2)
        raise ConfigError, "replace_record_key_regexp#{i} does not contain 2 parameters" unless replacement
        raise ConfigError, "replace_record_key_regexp#{i} contains a duplicated key, #{regexp}" if @regexps[regexp]
        @regexps[regexp] = replacement
      end

      @localtime = false if @localtime.nil? && @utc

      @timef = TimeFormatter.new(@time_format, @localtime)

      if @time_field
        keys = @time_field.split('.')
        last_key = keys.pop
        @add_time_field = ->(record, time) {
          keys.inject(record) { |h, k| h[k] ||= {} }[last_key] = @timef.format(time)
          record
        }
      else
        @add_time_field = ->(record, time) { record }
      end

      if @insert_id_field
        insert_id_keys = @insert_id_field.split('.')
        @get_insert_id = ->(record) {
          insert_id_keys.inject(record) {|h, k| h[k] }
        }
      else
        @get_insert_id = nil
      end
    end

    def start
      super

      @cached_client = nil
      @cached_client_expiration = nil

      @tables_queue = @tablelist.dup.shuffle
      @tables_mutex = Mutex.new
      @fetch_schema_mutex = Mutex.new

      @last_fetch_schema_time = 0
      fetch_schema(false) if @fetch_schema
    end

    def client
      return @cached_client if @cached_client && @cached_client_expiration > Time.now

      client = Google::Apis::BigqueryV2::BigqueryService.new

      scope = "https://www.googleapis.com/auth/bigquery"

      case @auth_method
      when 'private_key'
        require 'google/api_client/auth/key_utils'
        key = Google::APIClient::KeyUtils.load_from_pkcs12(@private_key_path, @private_key_passphrase)
        auth = Signet::OAuth2::Client.new(
                token_credential_uri: "https://accounts.google.com/o/oauth2/token",
                audience: "https://accounts.google.com/o/oauth2/token",
                scope: scope,
                issuer: @email,
                signing_key: key)

      when 'compute_engine'
        auth = Google::Auth::GCECredentials.new

      when 'json_key'
        if File.exist?(@json_key)
          auth = File.open(@json_key) do |f|
            Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: f, scope: scope)
          end
        else
          key = StringIO.new(@json_key)
          auth = Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: key, scope: scope)
        end

      when 'application_default'
        auth = Google::Auth.get_application_default([scope])

      else
        raise ConfigError, "Unknown auth method: #{@auth_method}"
      end

      client.authorization = auth

      @cached_client_expiration = Time.now + 1800
      @cached_client = client
    end

    def generate_table_id(table_id_format, current_time, row = nil, chunk = nil)
      format, col = table_id_format.split(/@/)
      time = if col && row
               keys = col.split('.')
               t = keys.inject(row[:json]) {|obj, attr| obj[attr.to_sym] }
               Time.at(t)
             else
               current_time
             end
      if row && format =~ /\$\{/
        format.gsub!(/\$\{\s*(\w+)\s*\}/) do |m|
          row[:json][$1.to_sym].to_s.gsub(/[^\w]/, '')
        end
      end
      table_id = time.strftime(format)

      if chunk
        table_id.gsub(%r(%{time_slice})) { |expr|
          chunk.key
        }
      else
        table_id.gsub(%r(%{time_slice})) { |expr|
          current_time.strftime(@time_slice_format)
        }
      end
    end

    def create_table(table_id)
      client.insert_table(@project, @dataset, {
        table_reference: {
          table_id: table_id,
        },
        schema: {
          fields: @fields.to_a,
        }
      }, {})
    rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError => e
      # api_error? -> client cache clear
      @cached_client = nil

      message = e.message
      if e.status_code == 409 && /Already Exists:/ =~ message
        # ignore 'Already Exists' error
        return
      end
      log.error "tables.insert API", :project_id => @project, :dataset => @dataset, :table => table_id, :code => e.status_code, :message => message
      raise "failed to create table in bigquery" # TODO: error class
    end

    def replace_record_key(record)
      new_record = {}
      record.each do |key, _|
        new_key = key
        @regexps.each do |regexp, replacement|
          new_key = new_key.gsub(/#{regexp}/, replacement)
        end
        new_key = new_key.gsub(/\W/, '')
        new_record.store(new_key, record[key])
      end
      new_record
    end

    def convert_hash_to_json(record)
      record.each do |key, value|
        if value.class == Hash
          record[key] = MultiJson.dump(value)
        end
      end
      record
    end

    def write(chunk)
      table_id_format = @tables_mutex.synchronize do
        t = @tables_queue.shift
        @tables_queue.push t
        t
      end
      template_suffix_format = @template_suffix
      _write(chunk, table_id_format, template_suffix_format)
    end

    def fetch_schema(allow_overwrite = true)
      table_id = nil
      @fetch_schema_mutex.synchronize do
        if Fluent::Engine.now - @last_fetch_schema_time > @schema_cache_expire
          table_id_format = @tablelist[0]
          table_id = generate_table_id(table_id_format, Time.at(Fluent::Engine.now))
          res = client.get_table(@project, @dataset, table_id)

          schema = res.schema.fields.as_json
          log.debug "Load schema from BigQuery: #{@project}:#{@dataset}.#{table_id} #{schema}"
          if allow_overwrite
            fields = Fluent::BigQuery::RecordSchema.new("record")
            fields.load_schema(schema, allow_overwrite)
            @fields = fields
          else
            @fields.load_schema(schema, allow_overwrite)
          end
          @last_fetch_schema_time = Fluent::Engine.now
        end
      end
    rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError => e
      # api_error? -> client cache clear
      @cached_client = nil
      message = e.message
      log.error "tables.get API", project_id: @project, dataset: @dataset, table: table_id, code: e.status_code, message: message
      if @fields.empty?
        raise "failed to fetch schema from bigquery" # TODO: error class
      else
        log.warn "Use previous schema"
        @last_fetch_schema_time = Fluent::Engine.now
      end
    end

    module InsertImplementation
      def format(tag, time, record)
        fetch_schema if @template_suffix

        if @replace_record_key
          record = replace_record_key(record)
        end

        if @convert_hash_to_json
          record = convert_hash_to_json(record)
        end

        buf = String.new
        row = @fields.format(@add_time_field.call(record, time))
        unless row.empty?
          row = {"json" => row}
          row['insert_id'] = @get_insert_id.call(record) if @get_insert_id
          buf << row.to_msgpack
        end
        buf
      end

      def _write(chunk, table_format, template_suffix_format)
        rows = []
        chunk.msgpack_each do |row_object|
          # TODO: row size limit
          rows << row_object.deep_symbolize_keys
        end

        now = Time.at(Fluent::Engine.now)
        group = rows.group_by do |row|
          [
            generate_table_id(table_format, now, row, chunk),
            template_suffix_format ? generate_table_id(template_suffix_format, now, row, chunk) : nil,
          ]
        end
        group.each do |(table_id, template_suffix), group_rows|
          insert(table_id, group_rows, template_suffix)
        end
      end

      def insert(table_id, rows, template_suffix)
        body = {
          rows: rows,
          skip_invalid_rows: @skip_invalid_rows,
          ignore_unknown_values: @ignore_unknown_values,
        }
        body.merge!(template_suffix: template_suffix) if template_suffix
        client.insert_all_table_data(@project, @dataset, table_id, body, {
          options: {timeout_sec: @request_timeout_sec, open_timeout_sec: @request_open_timeout_sec}
        })
      rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError => e
        # api_error? -> client cache clear
        @cached_client = nil

        if @auto_create_table && e.status_code == 404 && /Not Found: Table/i =~ e.message
          # Table Not Found: Auto Create Table
          create_table(table_id)
          raise "table created. send rows next time."
        end

        reason = e.respond_to?(:reason) ? e.reason : nil
        log.error "tabledata.insertAll API", project_id: @project, dataset: @dataset, table: table_id, code: e.status_code, message: e.message, reason: reason
        if RETRYABLE_ERROR_REASON.include?(reason)
          raise "failed to insert into bigquery, retry" # TODO: error class
        elsif @secondary
          flush_secondary(@secondary)
        end
      end
    end

    module LoadImplementation
      def format(tag, time, record)
        fetch_schema if @template_suffix

        if @replace_record_key
          record = replace_record_key(record)
        end

        buf = String.new
        row = @fields.format(@add_time_field.call(record, time))
        unless row.empty?
          buf << MultiJson.dump(row) + "\n"
        end
        buf
      end

      def _write(chunk, table_id_format, template_suffix_format)
        now = Time.at(Fluent::Engine.now)
        table_id = generate_table_id(table_id_format, now, nil, chunk)
        template_suffix = template_suffix_format ? generate_table_id(template_suffix_format, now, nil, chunk) : nil
        load(chunk, table_id, template_suffix)
      end

      def load(chunk, table_id, template_suffix)
        res = nil
        job_id = nil
        create_upload_source(chunk) do |upload_source|
          configuration, job_id = load_configuration(table_id, template_suffix, chunk)
          res = client.insert_job(
            @project,
            configuration,
            {
              upload_source: upload_source,
              content_type: "application/octet-stream",
              options: {
                timeout_sec: @request_timeout_sec,
                open_timeout_sec: @request_open_timeout_sec,
              }
            }
          )
        end
        wait_load(res.job_reference.job_id, table_id)
      rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError => e
        # api_error? -> client cache clear
        @cached_client = nil

        reason = e.respond_to?(:reason) ? e.reason : nil
        log.error "job.load API", project_id: @project, dataset: @dataset, table: table_id, code: e.status_code, message: e.message, reason: reason

        return wait_load(job_id, table_id) if job_id && e.status_code == 409 && e.message =~ /Job/ # duplicate load job

        if RETRYABLE_ERROR_REASON.include?(reason) || e.is_a?(Google::Apis::ServerError)
          raise "failed to insert into bigquery, retry" # TODO: error class
        elsif @secondary
          flush_secondary(@secondary)
        end
      end

      private

      def load_configuration(table_id, template_suffix, chunk)
        job_id = nil
        if @prevent_duplicate_load
          job_id = create_job_id(chunk, @dataset, "#{table_id}#{template_suffix}", @fields.to_a, @max_bad_records, @ignore_unknown_values)
        end

        configuration = {
          configuration: {
            load: {
              destination_table: {
                project_id: @project,
                dataset_id: @dataset,
                table_id: "#{table_id}#{template_suffix}",
              },
              schema: {
                fields: @fields.to_a,
              },
              write_disposition: "WRITE_APPEND",
              source_format: "NEWLINE_DELIMITED_JSON",
              ignore_unknown_values: @ignore_unknown_values,
              max_bad_records: @max_bad_records,
            }
          }
        }
        configuration.merge!({job_reference: {project_id: @project, job_id: job_id}}) if job_id

        # If target table is already exist, omit schema configuration.
        # Because schema changing is easier.
        begin
          if template_suffix && client.get_table(@project, @dataset, "#{table_id}#{template_suffix}")
            configuration[:configuration][:load].delete(:schema)
          end
        rescue Google::Apis::ServerError, Google::Apis::ClientError, Google::Apis::AuthorizationError
          raise "Schema is empty" if @fields.empty?
        end

        return configuration, job_id
      end

      def wait_load(job_id, table_id)
        wait_interval = 10
        _response = client.get_job(@project, job_id)

        until _response.status.state == "DONE"
          log.debug "wait for load job finish", state: _response.status.state, job_id: _response.job_reference.job_id
          sleep wait_interval
          _response = client.get_job(@project, _response.job_reference.job_id)
        end

        errors = _response.status.errors
        if errors
          errors.each do |e|
            log.error "job.insert API (rows)", job_id: job_id, project_id: @project, dataset: @dataset, table: table_id, message: e.message, reason: e.reason
          end
        end

        error_result = _response.status.error_result
        if error_result
          log.error "job.insert API (result)", job_id: job_id, project_id: @project, dataset: @dataset, table: table_id, message: error_result.message, reason: error_result.reason
          if RETRYABLE_ERROR_REASON.include?(error_result.reason)
            raise "failed to load into bigquery"
          elsif @secondary
            flush_secondary(@secondary)
          end
        end

        log.debug "finish load job", state: _response.status.state
      end

      def create_upload_source(chunk)
        chunk_is_file = @buffer_type == 'file'
        if chunk_is_file
          File.open(chunk.path) do |file|
            yield file
          end
        else
          Tempfile.open("chunk-tmp") do |file|
            file.binmode
            chunk.write_to(file)
            file.sync
            file.rewind
            yield file
          end
        end
      end

      def create_job_id(chunk, dataset, table, schema, max_bad_records, ignore_unknown_values)
        "fluentd_job_" + Digest::SHA1.hexdigest("#{chunk.unique_id}#{dataset}#{table}#{schema.to_s}#{max_bad_records}#{ignore_unknown_values}")
      end
    end
  end
end
