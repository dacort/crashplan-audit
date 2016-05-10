require 'net/http'
require 'json'
require 'highline'

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

def post(url, headers=nil, data=nil)
  uri = URI(url)
  req = Net::HTTP::Post.new(uri)
  req.body = data.to_json if data

  res = http_request(req, headers)

  # p res
  parsed_body =  JSON.parse(res.body)
  return parsed_body
end

def get(url, headers=nil)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)

  res = http_request(req, headers)

  # p res
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
  'https://www.crashplan.com/account/api/loginToken',
  {"username" => username, "password" => password},
  {"userId" => "my","sourceGuid" => "#{@selected_computer['guid']}","destinationGuid" => "42"}
)
p @login

@storage_creds = post(
  "#{@login['data']['serverUrl']}/account/api/authToken",
  {"Authorization" => "LOGIN_TOKEN #{@login['data']['loginToken']}"},
)
p @storage_creds

datakey = post(
  'https://www.crashplan.com/account/api/dataKeyToken',
  {"username" => username, "password" => password},
  {"computerGuid" => "#{@selected_computer['guid']}"}
)
p datakey

passphrase = cli.ask("Crashplan passphrase:   ") { |q| q.echo = "*" }
@webrestore = post(
  "#{@login['data']['serverUrl']}/account/api/webRestoreSession",
  {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"},
  {"computerGuid" => "#{@selected_computer['guid']}","dataKeyToken" => "#{datakey['data']['dataKeyToken']}","privatePassword" => passphrase}
)
p @webrestore

TEST_DIR="/Users/dacort"

# Iterate until we get to TEST_DIR
base_file_id = nil
recurse_params = nil
loop do
  resp = get(
    "#{@login['data']['serverUrl']}/account/api/webRestoreTreeNode?guid=#{@selected_computer['guid']}&webRestoreSessionId=#{@webrestore['data']['webRestoreSessionId']}#{recurse_params}",
    {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"}
  )
  match_dir = resp['data'].select{|d| d['path'] == TEST_DIR}
  if match_dir.any?
    p match_dir
    base_file_id = match_dir[0]['id']
    break
  end

  # Works for this case, but will need to make better
  recurse_params = "&fileId=#{resp['data'][0]['id']}&type=directory"
end

puts base_file_id
@missing_files = []

def find_missing_files(local_dir, cp_file_id)
  puts "  #{local_dir}:#{cp_file_id}"
  my_files = Dir.entries(local_dir)[2..-1].select{|entry| !@exclude_patterns.any?{|p| entry.match(p)}}
  cp_files = get(
    "#{@login['data']['serverUrl']}/account/api/webRestoreTreeNode?guid=#{@selected_computer['guid']}&webRestoreSessionId=#{@webrestore['data']['webRestoreSessionId']}&fileId=#{cp_file_id}&type=directory",
    {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"}
  )['data'] rescue [] # TODO: Better error handling. Always.
  # => [{"name"=>"SYSTEM", "description"=>"An error has occurred. See server logs for more information.", "objects"=>[]}]
  cp_filenames = cp_files.collect{|d| d['filename']}

  # p my_files
  # p cp_filenames

  missing_filenames = my_files - cp_filenames
  # p missing_filenames
  @missing_files.concat(missing_filenames.collect{|fn| File.join(local_dir, fn)})
  p @missing_files

  cp_files.each{|cp_file|
    next unless cp_file['type'] == 'directory'

    find_missing_files(cp_file['path'], cp_file['id'])
  }
end

# Get the list of files I know about
# Get the list of files that Crashplan knows about
find_missing_files(TEST_DIR, base_file_id)
# my_files = Dir.entries(TEST_DIR)[2..-1].select{|entry| !@exclude_patterns.any?{|p| entry.match(p)}}
# cp_files = get(
#   "#{@login['data']['serverUrl']}/account/api/webRestoreTreeNode?guid=#{@selected_computer['guid']}&webRestoreSessionId=#{@webrestore['data']['webRestoreSessionId']}&fileId=#{base_file_id}&type=directory",
#   {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"}
# )['data']
# cp_filenames = cp_files.collect{|d| d['filename']}
#
# p my_files
# p cp_filenames
#
# missing_files = my_files - cp_filenames
# p missing_files



# We've now collected files and directories that are missing.
# For ones that aren't, start descending and compare locally.


# resp = get(
#   "#{@login['data']['serverUrl']}/account/api/webRestoreTreeNode?guid=#{@selected_computer['guid']}&webRestoreSessionId=#{@webrestore['data']['webRestoreSessionId']}",
#   {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"}
# )
# p resp
#
# resp = get(
#   "#{@login['data']['serverUrl']}/account/api/webRestoreTreeNode?guid=#{@selected_computer['guid']}&webRestoreSessionId=#{@webrestore['data']['webRestoreSessionId']}&fileId=#{resp['data'][0]['id']}&type=directory",
#   {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"}
# )
# p resp
#
# puts
#
# resp = get(
#   "#{@login['data']['serverUrl']}/account/api/WebRestoreSearch?guid=#{@selected_computer['guid']}&webRestoreSessionId=#{@webrestore['data']['webRestoreSessionId']}&regex=\/Users\/dacort\/.*",
#   {"Authorization" => "TOKEN #{@storage_creds['data'].join('-')}"}
# )
# p resp
