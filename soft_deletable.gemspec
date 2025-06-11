# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = 'soft_deletable'
  s.version     = '1.0.0'
  s.date        = '2023-11-08'
  s.summary     = 'Soft delete implementation for Rails apps'
  s.description = 'Soft delete implementation for Rails apps'
  s.authors     = ['Luiz Filipe']
  s.email       = 'luizfilipeneves@gmail.com'
  s.files       = ['lib/soft_deletable.rb']
  s.require_paths = ['lib']
  s.homepage    = 'https://github.com/prosas/soft_deletable'
  s.license     = 'MIT'

  s.metadata['allowed_push_host'] = 'https://rubygems.org'
  s.add_development_dependency "rake", [">= 13"]
  s.add_development_dependency "sqlite3"
  s.add_development_dependency "minitest", [">= 5"]
  s.add_development_dependency "byebug", [">= 11"]
end
