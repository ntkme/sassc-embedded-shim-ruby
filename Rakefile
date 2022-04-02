# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rubocop/rake_task'

task default: %i[rubocop test rails:test]

desc 'Run all tests'
task :test do
  $LOAD_PATH.unshift('lib', 'test')
  Dir.glob('test/**/*_test.rb').sort.each { |f| require_relative f }
end

namespace :rails do
  submodule = 'vendor/github.com/sass/sassc-rails'

  desc "Init submodule #{submodule}"
  task :init do
    sh(*%w[git submodule update --init], submodule)
  end

  desc "Clean submodule #{submodule}"
  task clean: :init do
    sh(*%w[git reset --hard], chdir: submodule)
    sh(*%w[git clean -dffx], chdir: submodule)
  end

  desc "Patch submodule #{submodule}"
  task patch: :clean do
    sh(*%w[git apply], File.absolute_path('test/patches/sassc-rails.diff', __dir__), chdir: submodule)
  end

  desc "Test submodule #{submodule}"
  task test: :patch do
    Bundler.with_original_env do
      %w[
        Gemfile
        gemfiles/rails_6_0.gemfile
        gemfiles/sprockets_4_0.gemfile
        gemfiles/sprockets-rails_3_0.gemfile
      ].each do |gemfile|
        env = { 'BUNDLE_GEMFILE' => gemfile }
        sh(env, *%w[bundle install], chdir: submodule)
        sh(env, *%w[bundle exec rake test], chdir: submodule)
      end
    end
    Rake::Task['rails:clean'].execute
  end
end

RuboCop::RakeTask.new
