warn "The Rails 4 Rack boundary is retired; use ./start.sh."
exit 78

# This file is used by Rack-based servers to start the application.

require ::File.expand_path('../config/environment', __FILE__)
run Rails.application
