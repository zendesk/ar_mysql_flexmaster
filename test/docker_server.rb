require 'mysql2'

# The DB setup logic from isolated_server, for docker
module DockerServer
  class MySql
    Binlog = Struct.new(:file, :pos)

    attr_reader :host

    def initialize(host:)
      @host = host
    end

    def query(sql, options = {})
      puts "#{host}: #{sql}"
      client.query(sql, options)
    end

    def make_master
      query(
        "CHANGE MASTER TO MASTER_HOST='#{host}', " \
        "MASTER_USER='root', " \
        "MASTER_PASSWORD=''"
      )
    end

    def make_slave_of(master)
      master_binlog = master.binlog

      query(
        "CHANGE MASTER TO MASTER_HOST='#{master.host}', " \
        "MASTER_USER='root', " \
        "MASTER_PASSWORD='', " \
        "MASTER_LOG_FILE='#{master_binlog.file}', " \
        "MASTER_LOG_POS=#{master_binlog.pos}"
      )
      query("START SLAVE")
      set_ro!
    end

    def up?
      puts "Up? #{host}"
      client
    rescue Mysql2::Error
      false
    end

    def synced_with?(master)
      master_pos = master.query("SHOW MASTER STATUS").to_a.first["Position"]
      pos = query("SHOW SLAVE STATUS").to_a.first["Exec_Master_Log_Pos"]
      pos == master_pos
    end

    def set_ro!
      query("SET GLOBAL READ_ONLY=ON")
    end

    def set_rw!
      query("SET GLOBAL READ_ONLY=OFF")
    end

    def reconnect!
      disconnect!
      client
    end

    def binlog
      result = query("SHOW MASTER STATUS").first
      Binlog.new(result['File'], result['Position'])
    end

    def server_id
      @server_id ||= begin
        result = query("SHOW GLOBAL VARIABLES LIKE 'server_id'").first
        result['Value'].to_i
      end
    end

    private

    def client
      @client ||= Mysql2::Client.new(
        host: host,
        username: "root",
        password: ""
      )
    end

    def disconnect!
      @client = nil
    end
  end
end
