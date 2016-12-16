require 'net/http'
require 'json'
require 'highline'
require './db'

# The target directory we want to compare against.
# Defaults to the user's home directory.
TEST_DIR="$HOME"

# A list of files or folders in TEST_DIR to explicitly ignore.
# Typically these are not critical and contain installation packages or caches.
IGNORE = [
  '.atom/.apm',
  '.atom/packages',
  '.berkshelf',
  '.cache',
  '.heroku',
  '.local',
  '.m2',
  '.node-gyp',
  '.nodenv',
  '.npm',
  '.rbenv',
  '.vim',
  '.vscode',
  'Applications',
].map{|p| File.join(TEST_DIR, p)}

# A list of directories to ignore, regardless of where they are.
# These tend to have a lot of files that can be recreated easily.
IGNORE_DIRS = [
  'bower_components',
  'node_modules',
  'site-packages',
  'venv',
]

# Initialize a database to log our state into.
@database = DB.new

# HTTP Request builder for Crashplan API
def http_request(req, headers={})
  if headers.has_key?("username") && headers.has_key?("password")
    req.basic_auth(headers.delete("username"), headers.delete("password"))
  end

  req['Content-Type'] = "application/json; charset=UTF-8"

  headers.each{|k,v| req[k] = v}

  return Net::HTTP.start(req.uri.hostname, req.uri.port,:use_ssl => req.uri.scheme == 'https') {|http|
    http.request(req)
  }
end

# HTTP POST requst builder
def post(url, headers=nil, data=nil)
  uri = URI(url)
  req = Net::HTTP::Post.new(uri)
  req.body = data.to_json if data

  res = http_request(req, headers)

  parsed_body =  JSON.parse(res.body)
  return parsed_body
end

# HTTP GET request builder
def get(url, headers=nil)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)

  res = http_request(req, headers)

  parsed_body =  JSON.parse(res.body)
  return parsed_body
end

# Get the username & password
cli = HighLine.new
username = cli.ask "Crashplan Username:   "
password = cli.ask("Crashplan password:   ") { |q| q.echo = "*" }

computers = get(
  'https://www.crashplan.com/api/Computer?incBackupUsage=true&active=true',
  {"username" => username, "password" => password},
)

# Ask the user to select a computer
computer_names = computers['data']['computers'].collect{|c| c['name']}
selected_computer_id = cli.ask("Select a computer:\n#{computer_names.collect.with_index{|c,i| "#{i+1}. #{c}"}.join("\n")}\n> ", Integer) { |q| q.in = 1..computer_names.length }

@selected_computer = computers['data']['computers'][selected_computer_id-1]
p @selected_computer

computer_metadata = get(
  "https://www.crashplan.com/api/Computer/#{@selected_computer['guid']}?idType=guid&incBackupUsage=true&active=true&incSettings=true",
  {"username" => username, "password" => password}
)
local_paths = computer_metadata['data']['settings']['serviceBackupConfig']['backupConfig']['backupSets']

@exclude_patterns = computer_metadata['data']['settings']['serviceBackupConfig']['backupConfig']['excludeSystem'][0].select{|k,r|
  ['pattern', 'macintosh'].include?(k)
}.collect{|k,v| v.collect{|item| item['@regex']}}.flatten.compact

@login = post(
  'https://www.crashplan.com/api/loginToken',
  {"username" => username, "password" => password},
  {"userId" => "my","sourceGuid" => "#{@selected_computer['guid']}","destinationGuid" => "42"}
)
p @login

@storage_creds = post(
  "#{@login['data']['serverUrl']}/api/authToken",
  {"Authorization" => "LOGIN_TOKEN #{@login['data']['loginToken']}"},
)
p @storage_creds

datakey = post(
  'https://www.crashplan.com/api/dataKeyToken',
  {"username" => username, "password" => password},
  {"computerGuid" => "#{@selected_computer['guid']}"}
)
p datakey

passphrase = cli.ask("Crashplan passphrase:   ") { |q| q.echo = "*" }
@webrestore = post(
  "#{@login['data']['serverUrl']}/api/webRestoreSession",
  {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"},
  {"computerGuid" => "#{@selected_computer['guid']}","dataKeyToken" => "#{datakey['data']['dataKeyToken']}","privatePassword" => passphrase}
)
p @webrestore

# Iterate until we get to TEST_DIR
base_file_id = nil
recurse_params = nil
loop do
  resp = get(
    "#{@login['data']['serverUrl']}/api/webRestoreTreeNode?guid=#{@selected_computer['guid']}&webRestoreSessionId=#{@webrestore['data']['webRestoreSessionId']}#{recurse_params}",
    {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"}
  )
  match_dir = resp['data'].select{|d| d['path'] == TEST_DIR}
  if match_dir.any?
    base_file_id = match_dir[0]['id']
    break
  end

  # Works for this case, but will need to make better
  recurse_params = "&fileId=#{resp['data'][0]['id']}&type=directory"
end

def find_missing_files(local_dir, cp_file_id)
  puts "  Examining #{local_dir}"
  my_files = Dir.entries(local_dir)[2..-1].select{|entry| !@exclude_patterns.any?{|p| entry.match(p)}}
  cp_files = get(
    "#{@login['data']['serverUrl']}/account/api/webRestoreTreeNode?guid=#{@selected_computer['guid']}&webRestoreSessionId=#{@webrestore['data']['webRestoreSessionId']}&fileId=#{cp_file_id}&type=directory",
    {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"}
  )['data'] # TODO: Better error handling. Always.
  # => [{"name"=>"SYSTEM", "description"=>"An error has occurred. See server logs for more information.", "objects"=>[]}]
  cp_filenames = cp_files.collect{|d| d['filename']}

  # Verify that all files and directories have been backed up.
  # We'll initially mark a directory as "missing" until we've
  # fully traversed it.
  # This is so if we don't need to descend down them again when
  # the script breaks and we have to re-run it. :)
  my_files.each{|my_file|
    full_path = File.join(local_dir, my_file)
    is_dir = File.directory?(full_path)

    backed_up = cp_filenames.include?(my_file)
    cp_file = cp_files.find{|cp_file| cp_file['filename'] == my_file}

    @database.record_status(
      full_path,
      cp_file ? cp_file['id'] : nil,
      (backed_up) ? 'verified' : 'missing'
    ) if !is_dir
  }

  # Now traverse into each directory
  my_files.each{|my_file|
    full_path = File.join(local_dir, my_file)
    next unless File.directory?(full_path)

    # Ignore the ignored directories
    next if IGNORE.include?(full_path)
    next if IGNORE_DIRS.include?(my_file)

    cp_file = cp_files.find{|cp_file| cp_file['filename'] == my_file}

    # If cp_file is nil, mark it as missing and don't bother traversing.
    if cp_file.nil?
      @database.record_status(
        full_path,
        cp_file ? cp_file['id'] : nil,
        'missing'
      )
      next
    end

    # If we already full traversed this path don't bother again
    dir_status = @database.find_file(cp_file['path'])
    next if (dir_status && dir_status[3] == 0)

    find_missing_files(cp_file['path'], cp_file['id'])

    # Mark this specific path as *verified*, indicating only that
    # we fully traversed it at this point in time.
    @database.record_status(
      full_path,
      cp_file['id'],
      'verified'
    )
  }
end

# Start at TEST_DIR and find missing files in all directories
# except for the relative paths specified in IGNORE.
find_missing_files(TEST_DIR, base_file_id)
