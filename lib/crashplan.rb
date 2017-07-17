require 'highline'

class Crashplan
  def login
    # Get the username & password
    @cli = HighLine.new
    @username = @cli.ask "Crashplan Username:   "
    @password = @cli.ask("Crashplan password:   ") { |q| q.echo = "*" }
  end

  def select_computer
    # Ask the user to select a computer
    computer_names = computers['data']['computers'].collect{|c| c['name']}
    selected_computer_id = @cli.ask("Select a computer:\n#{computer_names.collect.with_index{|c,i| "#{i+1}. #{c}"}.join("\n")}\n> ", Integer) { |q| q.in = 1..computer_names.length }

    @selected_computer = computers['data']['computers'][selected_computer_id-1]
  end

  def computers
    @computers ||= get(
      'https://www.crashplan.com/api/Computer?incBackupUsage=true&active=true',
      {"username" => @username, "password" => @password},
    )
  end

  def computer_metadata(computer_guid)
    get(
      "https://www.crashplan.com/api/Computer/#{computer_guid}?idType=guid&incBackupUsage=true&active=true&incSettings=true",
      {"username" => @username, "password" => @password}
    )
  end

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
end
