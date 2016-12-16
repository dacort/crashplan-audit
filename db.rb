require 'sqlite3'
require 'digest'

class DB
  FILE_STATUS = ['verified', 'missing', 'error']

  def initialize
    @db = SQLite3::Database.new "cpaudit.db"
    initialize_tables
  end

  def find_file(path)
    return @db.execute("select * from file_audit WHERE hash='#{hash_file(path)}' ORDER BY inserted_at DESC LIMIT 1")[0]
  end

  def record_status(path, fileid, status)
    raise Exception.new("Invalid status") unless FILE_STATUS.include?(status)

    @db.execute("insert or replace into file_audit (path, hash, cp_fileid, status_id, inserted_at) VALUES (?,?,?,?,?)",
      [path, hash_file(path), fileid, FILE_STATUS.index(status), Time.now.utc.iso8601]
    )
  end

  def hash_file(path)
    Digest::MD5.hexdigest(path)
  end

  def initialize_tables
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS file_audit (
        path text,
        hash varchar(32),
        cp_fileid varchar(32),
        status_id integer,
        inserted_at datetime
      );
    SQL
    @db.execute <<-SQL
      CREATE UNIQUE INDEX IF NOT EXISTS file_idx ON file_audit(hash, inserted_at);
    SQL
  end
end
