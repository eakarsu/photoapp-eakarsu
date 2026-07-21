warn "The Rails 4 boot boundary is retired; use ./start.sh."
exit 78

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../Gemfile', __FILE__)

require 'bundler/setup' # Set up gems listed in the Gemfile.
