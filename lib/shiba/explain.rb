require 'json'
require 'shiba/index'

module Shiba
  class Explain
    def initialize(sql, stats, options = {})
      @sql = sql

      if options[:force_key]
         @sql = @sql.sub(/(FROM\s*\S+)/i, '\1' + " FORCE INDEX(`#{options[:force_key]}`)")
      end

      @options = options
      ex = Shiba.connection.query("EXPLAIN FORMAT=JSON #{@sql}").to_a
      json = JSON.parse(ex.first['EXPLAIN'])
      @rows = self.class.transform_json(json['query_block'])
      @stats = stats
      run_checks!
    end

    def self.transform_table(table)
      t = table['table']
      res = {}
      res['table'] = t['table_name']
      res['access_type'] = t['access_type']
      res['key'] = t['key']
      res['used_key_parts'] = t['used_key_parts'] if t['used_key_parts']
      res['rows'] = t['rows_examined_per_scan']

      if t['possible_keys'] && t['possible_keys'] != [res['key']]
        res['possible_keys'] = t['possible_keys']
      end
      res['using_index'] = t['using_index'] if t['using_index']
      res
    end

    def self.transform_json(json)
      rows = []

      if json['ordering_operation']
        return transform_json(json['ordering_operation'])
      elsif json['duplicates_removal']
        return transform_json(json['duplicates_removal'])
      elsif !json['nested_loop'] && !json['table']
        return [{'Extra' => json['message']}]
      elsif !json['nested_loop']
        json['nested_loop'] = [{'table' => json['table']}]
      end

      json['nested_loop'].map do |o|
        transform_table(o)
      end
    end

    # [{"id"=>1, "select_type"=>"SIMPLE", "table"=>"interwiki", "partitions"=>nil, "type"=>"const", "possible_keys"=>"PRIMARY", "key"=>"PRIMARY", "key_len"=>"34", "ref"=>"const", "rows"=>1, "filtered"=>100.0, "Extra"=>nil}]
    attr_reader :cost

    def first
      @rows.first
    end

    def first_table
      first["table"]
    end

    def first_key
      first["key"]
    end

    def first_extra
      first["Extra"]
    end

    def messages
      @messages ||= []
    end

    # shiba: {"possible_keys"=>nil, "key"=>nil, "key_len"=>nil, "ref"=>nil, "rows"=>6, "filtered"=>16.67, "Extra"=>"Using where"}
    def to_log
      "possible: '%{possible_keys}', rows: %{rows}, filtered: %{filtered}, cost: #{self.cost},'%{Extra}'" % first.symbolize_keys
    end

    def to_h
      first.merge(cost: cost, messages: messages)
    end

    IGNORE_PATTERNS = [
      /no matching row in const table/,
      /No tables used/,
      /Impossible WHERE/,
      /Select tables optimized away/,
      /No matching min\/max row/
    ]

    def table_size
      Shiba::Index.count(first["table"], @stats)
    end

    def ignore_explain?
      first_extra && IGNORE_PATTERNS.any? { |p| first_extra =~ p }
    end

    def derived?
      first['table'] =~ /<derived.*?>/
    end

    # TODO: need to parse SQL here I think
    def simple_table_scan?
      @rows.size == 1 && (@sql !~ /where/i || @sql =~ /where\s*1=1/i) && (@sql !~ /order by/i)
    end

    def estimate_row_count
      return 0 if ignore_explain?

      if simple_table_scan?
        if @sql =~ /limit\s*(\d+)/i
          return $1.to_i
        else
          return table_size
        end
      end

      if derived?
        # select count(*) from ( select 1 from foo where blah )
        @rows.shift
        return estimate_row_count
      end

      # TODO: if possible_keys but mysql chooses NULL, this could be a test-data issue,
      # pick the best key from the list of possibilities.
      #

      messages << "fuzzed_data" if Shiba::Index.fuzzed?(first_table, @stats)

      if first_key
        Shiba::Index.estimate_key(first_table, first_key, first['used_key_parts'], @stats)
      else
        if first['possible_keys'].nil?
          # if no possibile we're table scanning, use PRIMARY to indicate that cost.
          # note that this can be wildly inaccurate bcs of WHERE + LIMIT stuff.
          Shiba::Index.count(first_table, @stats)
        else
          if @options[:force_key]
            # we were asked to force a key, but mysql still told us to fuck ourselves.
            # (no index used)
            #
            # there seems to be cases where mysql lists `possible_key` values
            # that it then cannot use, seen this in OR queries.
            return Shiba::Index.count(first_table, @stats)
          end

          messages << "possible_key_check"
          possibilities = [Shiba::Index.count(first_table, @stats)]
          possibilities += first['possible_keys'].map do |key|
            estimate_row_count_with_key(key)
          end
          possibilities.compact.min
        end
      end
    end

    def estimate_row_count_with_key(key)
      Explain.new(@sql, @stats, force_key: key).estimate_row_count
    rescue Mysql2::Error => e
      if /Key .+? doesn't exist in table/ =~ e.message
        return nil
      end

      raise e
    end

    def run_checks!
      @cost = estimate_row_count
    end
  end
end

