require 'shiba/index_stats'
require 'shiba/fuzzer'

module Shiba
  class TableStats
    def initialize(dump_stats, connection, manual_stats)
      @dump_stats = Shiba::IndexStats.new(dump_stats)
      @db_stats = Shiba::Fuzzer.new(connection).fuzz!
      @manual_stats = Shiba::IndexStats.new(manual_stats)
    end


    def estimate_key(table_name, key, parts)
      ask_each(:estimate_key, table_name, key, parts)
    end

    def table_count(table)
      ask_each(:table_count, table)
    end

    private
    def ask_each(method, *args)
      [@manual_stats, @dump_stats, @db_stats].each do |stat|
        result = stat.send(method, *args)
        return result unless result.nil?
      end
      nil
    end
  end
end