#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to analyze which SOAP operations use ResponseMessageType in their responses
# Run from project root: ruby scripts/analyze_wsdl_response_types.rb

require 'nokogiri'
require 'pathname'

WSDL_DIR = Pathname.new(File.expand_path('../lib/wsdl', __dir__))

class WsdlAnalyzer
  Result = Struct.new(:operation, :has_response_message_xsd, :response_type_name, :uses_response_message_type, :response_element_path, keyword_init: true)

  def initialize(operation_dir)
    @operation_dir = operation_dir
    @operation_name = operation_dir.basename.to_s
  end

  def analyze
    Result.new(
      operation: @operation_name,
      has_response_message_xsd: has_response_message_xsd?,
      response_type_name: response_type_name,
      uses_response_message_type: uses_response_message_type?,
      response_element_path: response_element_path
    )
  end

  private

  def has_response_message_xsd?
    response_message_xsd_path.exist?
  end

  def response_message_xsd_path
    # Check both patterns: ./xsd/ResponseMessage.xsd and ./ResponseMessage.xsd
    xsd_path = @operation_dir.join('xsd', 'ResponseMessage.xsd')
    return xsd_path if xsd_path.exist?

    @operation_dir.join('ResponseMessage.xsd')
  end

  def main_xsd_path
    # The main XSD usually matches the operation name
    xsd_in_subdir = @operation_dir.join('xsd', "#{@operation_name}.xsd")
    return xsd_in_subdir if xsd_in_subdir.exist?

    xsd_in_root = @operation_dir.join("#{@operation_name}.xsd")
    return xsd_in_root if xsd_in_root.exist?

    # Fallback: find any XSD that defines the response type
    Dir.glob(@operation_dir.join('**', '*.xsd')).find do |path|
      content = File.read(path)
      content.include?('ResponseType') || content.include?('Response"')
    end
  end

  def main_xsd_doc
    return nil unless main_xsd_path && File.exist?(main_xsd_path)

    @main_xsd_doc ||= Nokogiri::XML(File.read(main_xsd_path))
  end

  def response_type_name
    return nil unless main_xsd_doc

    # Look for complexType with "Response" in the name
    response_types = main_xsd_doc.xpath('//*[local-name()="complexType"]').select do |node|
      name = node['name'].to_s
      name.include?('Response') && !name.include?('Request')
    end

    response_types.map { |node| node['name'] }.join(', ')
  end

  def uses_response_message_type?
    return false unless main_xsd_doc

    # Check if any response type contains an element of type ResponseMessageType
    main_xsd_doc.xpath('//*[local-name()="element"]').any? do |element|
      type = element['type'].to_s
      type.include?('ResponseMessageType') || type == 'ResponseMessageType'
    end
  end

  def response_element_path
    return nil unless main_xsd_doc && uses_response_message_type?

    # Find the response element that contains ResponseMessageType
    # This helps us know the path to dig into

    # First, find the response type definition
    response_type = main_xsd_doc.xpath('//*[local-name()="complexType"]').find do |node|
      name = node['name'].to_s
      name.include?('ResponseType') && !name.include?('Request')
    end

    return nil unless response_type

    # Find the element within it that references ResponseMessageType
    response_message_element = response_type.xpath('.//*[local-name()="element"]').find do |element|
      type = element['type'].to_s
      type.include?('ResponseMessageType')
    end

    return nil unless response_message_element

    element_name = response_message_element['name']

    # Now find the root response element name
    root_element = main_xsd_doc.xpath('//*[local-name()="element"]').find do |element|
      type = element['type'].to_s
      type.include?('ResponseType') && !type.include?('Request') && element.parent.name == 'schema'
    end

    root_name = root_element&.[]('name') || "#{@operation_name}ResponseElement"

    # Convert to Ruby snake_case symbol path
    root_snake = to_snake_case(root_name)
    element_snake = to_snake_case(element_name)

    ":#{root_snake}, :#{element_snake}, :result_message_code"
  end

  def to_snake_case(str)
    str.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
       .gsub(/([a-z\d])([A-Z])/, '\1_\2')
       .downcase
  end
end

# Main execution
puts "Analyzing WSDL operations in #{WSDL_DIR}..."
puts "=" * 80

results = []

WSDL_DIR.children.select(&:directory?).sort.each do |operation_dir|
  analyzer = WsdlAnalyzer.new(operation_dir)
  results << analyzer.analyze
end

# Group results
with_response_message = results.select(&:uses_response_message_type)
without_response_message = results.reject(&:uses_response_message_type)

puts "\n## Operations WITH ResponseMessageType (can add extract_fdr_error_code):\n\n"

with_response_message.each do |result|
  puts "  #{result.operation}"
  puts "    Response type: #{result.response_type_name}"
  puts "    Path: response.body.dig(#{result.response_element_path})"
  puts
end

puts "\n## Operations WITHOUT ResponseMessageType:\n\n"

without_response_message.each do |result|
  puts "  #{result.operation}"
  puts "    Response type: #{result.response_type_name || '(not found)'}"
  puts "    Has ResponseMessage.xsd: #{result.has_response_message_xsd}"
  puts
end

puts "=" * 80
puts "Summary:"
puts "  With ResponseMessageType: #{with_response_message.count}"
puts "  Without: #{without_response_message.count}"
puts "  Total: #{results.count}"

# Output Ruby code snippet for easy copy-paste
puts "\n" + "=" * 80
puts "## Suggested extract_fdr_error_code implementations:\n\n"

with_response_message.each do |result|
  puts <<~RUBY
    # #{result.operation}
    def extract_fdr_error_code(response)
      response.body.dig(#{result.response_element_path})
    end

  RUBY
end

