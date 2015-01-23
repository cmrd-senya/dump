require 'capistrano/version'

if defined?(Capistrano::Version) && Capistrano::Version::MAJOR == 2
  require 'dump/capistrano/v2'
else
  require 'dump/capistrano/v3'
end
