source 'https://rubygems.org'

gemspec

if RUBY_VERSION.start_with? '1.9.'
    gem 'net-ssh', '< 3'
else
    gem 'net-ssh'
end

group :development do
  gem 'pry'
end

# load local gemfile
local_gemfile = File.join(File.dirname(__FILE__), 'Gemfile.local.rb')
self.instance_eval(Bundler.read_file(local_gemfile)) if File.exist?(local_gemfile)
