# frozen_string_literal: true

require 'sassc'
require 'sass-embedded'

require 'base64'
require 'json'
require 'pathname'
require 'uri'

require_relative 'embedded/version'

module SassC
  class Engine
    def render
      return @template.dup if @template.empty?

      result = ::Sass.compile_string(
        @template,
        importer: nil,
        load_paths: load_paths,
        syntax: syntax,
        url: file_url,

        source_map: !source_map_file.nil?,
        source_map_include_sources: source_map_contents?,
        style: output_style,

        functions: FunctionsHandler.new(@options).setup(nil, functions: @functions),
        importers: ImportHandler.new(@options).setup(nil),

        alert_ascii: @options.fetch(:alert_ascii, false),
        alert_color: @options.fetch(:alert_color, nil),
        logger: @options.fetch(:logger, nil),
        quiet_deps: @options.fetch(:quiet_deps, false),
        verbose: @options.fetch(:verbose, false)
      )

      @dependencies = result.loaded_urls
                            .filter { |url| url.start_with?('file:') && url != file_url }
                            .map { |url| Util.file_url_to_path(url) }
      @source_map   = post_process_source_map(result.source_map)

      return post_process_css(result.css) unless quiet?
    rescue ::Sass::CompileError => e
      line = e.span&.start&.line
      line += 1 unless line.nil?
      path = Util.file_url_to_path(e.span&.url)
      path = relative_path(Dir.pwd, path)
      raise SyntaxError.new(e.message, filename: path, line: line)
    end

    private

    def file_url
      @file_url ||= Util.path_to_file_url(filename || 'stdin')
    end

    def syntax
      syntax = @options.fetch(:syntax, :scss)
      syntax = :indented if syntax.to_sym == :sass
      syntax
    end

    def output_style
      @output_style ||= begin
        style = @options.fetch(:style, :sass_style_nested).to_s
        style = "sass_style_#{style}" unless style.include?('sass_style_')
        raise InvalidStyleError unless OUTPUT_STYLES.include?(style.to_sym)

        style = style.delete_prefix('sass_style_').to_sym
        case style
        when :nested
          :expanded
        when :compact
          :compressed
        else
          style
        end
      end
    end

    def load_paths
      @load_paths ||= (@options[:load_paths] || []) + SassC.load_paths
    end

    def post_process_source_map(source_map)
      return unless source_map

      data = JSON.parse(source_map)

      data['sources'].map! do |source|
        if source.start_with? 'file:'
          relative_path(Dir.pwd, Util.file_url_to_path(source))
        else
          source
        end
      end

      -JSON.generate(data)
    end

    def post_process_css(css)
      css += "\n" if css.end_with? '}'
      unless @source_map.nil? || omit_source_map_url?
        url = if source_map_embed?
                "data:application/json;base64,#{Base64.strict_encode64(@source_map)}"
              else
                URI::DEFAULT_PARSER.escape(source_map_file)
              end
        css += "\n/*# sourceMappingURL=#{url} */"
      end
      -css
    end

    def relative_path(from, to)
      Pathname.new(to).relative_path_from(Pathname.new(from)).to_s
    end
  end

  class FunctionsHandler
    def setup(_native_options, functions: Script::Functions)
      @callbacks = {}

      functions_wrapper = Class.new do
        attr_accessor :options

        include functions
      end.new
      functions_wrapper.options = @options

      Script.custom_functions(functions: functions).each do |custom_function|
        callback = lambda do |native_argument_list|
          function_arguments = arguments_from_native_list(native_argument_list)
          begin
            result = functions_wrapper.send(custom_function, *function_arguments)
          rescue StandardError
            raise ::Sass::ScriptError, "Error: error in C function #{custom_function}"
          end
          to_native_value(result)
        rescue StandardError => e
          warn "[SassC::FunctionsHandler] #{e.cause.message}"
          raise e
        end

        @callbacks[Script.formatted_function_name(custom_function, functions: functions)] = callback
      end

      @callbacks
    end

    private

    def arguments_from_native_list(native_argument_list)
      native_argument_list.map do |embedded_value|
        Script::ValueConversion.from_native embedded_value
      end
    end

    begin
      begin
        raise
      rescue StandardError
        raise ::Sass::ScriptError
      end
    rescue StandardError => e
      unless e.full_message.include? e.cause.full_message
        ::Sass::ScriptError.class_eval do
          def full_message(*args, **kwargs)
            full_message = super(*args, **kwargs)
            if cause
              "#{full_message}\n#{cause.full_message(*args, **kwargs)}"
            else
              full_message
            end
          end
        end
      end
    end
  end

  class ImportHandler
    def setup(_native_options)
      if @importer
        [FileImporter.new, Importer.new(@importer)]
      else
        [FileImporter.new]
      end
    end

    class FileImporter
      def find_file_url(url, **_kwargs)
        return url if url.start_with?('file:')
      end
    end

    private_constant :FileImporter

    class Importer
      def initialize(importer)
        @importer = importer
        @importer_results = {}
      end

      def canonicalize(url, **)
        path = Util.file_url_to_path(url)
        canonical_url = Util.path_to_file_url(File.absolute_path(path))

        if @importer_results.key?(canonical_url)
          return if @importer_results[canonical_url].nil?

          return canonical_url
        end

        canonical_url = "sass-importer-shim:#{canonical_url}"

        imports = @importer.imports path, @importer.options[:filename]
        unless imports.is_a? Array
          return if imports.path == path

          imports = [imports]
        end

        contents = imports.map do |import|
          import_path = File.absolute_path(import.path)
          import_url = Util.path_to_file_url(import_path)
          @importer_results[import_url] = if import.source
                                            {
                                              contents: import.source,
                                              syntax: case import.path
                                                      when /\.scss$/i
                                                        :scss
                                                      when /\.sass$/i
                                                        :indented
                                                      when /\.css$/i
                                                        :css
                                                      else
                                                        raise ArgumentError
                                                      end,
                                              source_map_url: if import.source_map_path
                                                                Util.path_to_file_url(
                                                                  File.absolute_path(import.source_map_path, path)
                                                                )
                                                              end
                                            }
                                          end
          "@import #{import_url.inspect};"
        end.join("\n")

        @importer_results[canonical_url] = {
          contents: contents,
          syntax: :scss
        }

        canonical_url
      end

      def load(canonical_url)
        @importer_results[canonical_url]
      end
    end

    private_constant :Importer
  end

  module Script
    module ValueConversion
      def self.to_native(value)
        case value
        when nil
          ::Sass::Value::Null::NULL
        when ::SassC::Script::Value::Bool
          ::Sass::Value::Boolean.new(value.to_bool)
        when ::SassC::Script::Value::Color
          if value.rgba?
            ::Sass::Value::Color.new(
              red: value.red,
              green: value.green,
              blue: value.blue,
              alpha: value.alpha
            )
          elsif value.hlsa?
            ::Sass::Value::Color.new(
              hue: value.hue,
              saturation: value.saturation,
              lightness: value.lightness,
              alpha: value.alpha
            )
          else
            raise ArgumentError
          end
        when ::SassC::Script::Value::List
          ::Sass::Value::List.new(
            value.to_a.map { |element| to_native(element) },
            separator: case value.separator
                       when :comma
                         ','
                       when :space
                         ' '
                       else
                         raise ArgumentError
                       end,
            bracketed: value.bracketed
          )
        when ::SassC::Script::Value::Map
          ::Sass::Value::Map.new(
            value.value.to_a.to_h { |k, v| [to_native(k), to_native(v)] }
          )
        when ::SassC::Script::Value::Number
          ::Sass::Value::Number.new(
            value.value, {
              numerator_units: value.numerator_units,
              denominator_units: value.denominator_units
            }
          )
        when ::SassC::Script::Value::String
          ::Sass::Value::String.new(
            value.value,
            quoted: value.type != :identifier
          )
        else
          raise ArgumentError
        end
      end

      def self.from_native(value)
        case value
        when ::Sass::Value::Null::NULL
          nil
        when ::Sass::Value::Boolean
          ::SassC::Script::Value::Bool.new(value.to_bool)
        when ::Sass::Value::Color
          if value.instance_eval { defined? @hue }
            ::SassC::Script::Value::Color.new(
              hue: value.hue,
              saturation: value.saturation,
              lightness: value.lightness,
              alpha: value.alpha
            )
          else
            ::SassC::Script::Value::Color.new(
              red: value.red,
              green: value.green,
              blue: value.blue,
              alpha: value.alpha
            )
          end
        when ::Sass::Value::List
          ::SassC::Script::Value::List.new(
            value.to_a.map { |element| from_native(element) },
            separator: case value.separator
                       when ','
                         :comma
                       when ' '
                         :space
                       else
                         raise ArgumentError
                       end,
            bracketed: value.bracketed?
          )
        when ::Sass::Value::Map
          ::SassC::Script::Value::Map.new(
            value.contents.to_a.to_h { |k, v| [from_native(k), from_native(v)] }
          )
        when ::Sass::Value::Number
          ::SassC::Script::Value::Number.new(
            value.value,
            value.numerator_units,
            value.denominator_units
          )
        when ::Sass::Value::String
          ::SassC::Script::Value::String.new(
            value.text,
            value.quoted? ? :string : :identifier
          )
        else
          raise ArgumentError
        end
      end
    end
  end

  module Util
    module_function

    def file_url_to_path(url)
      return if url.nil?

      path = URI::DEFAULT_PARSER.unescape(URI.parse(url).path)
      path = path[1..] if Gem.win_platform? && path[0].chr == '/' && path[1].chr =~ /[a-z]/i && path[2].chr == ':'
      path
    end

    def path_to_file_url(path)
      return if path.nil?

      path = File.absolute_path(path)
      path = "/#{path}" unless path.start_with? '/'
      URI::File.build([nil, URI::DEFAULT_PARSER.escape(path)]).to_s
    end
  end
end