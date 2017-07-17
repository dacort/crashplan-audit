require 'net/http'
require 'json'
require 'highline'
require './lib/crashplan'

@cp = Crashplan.new
@cp.login
@cp.select_computer
