# frozen_string_literal: true

# P18/C8 — coverage hook loaded into each product-behavior test subprocess via
# RUBYOPT. Starts stdlib Coverage (methods + lines), and on process exit dumps
# the result to $COVERAGE_DUMP (a per-test JSON file) so the audit generator
# can merge artifacts by canonical source path.

require "coverage"
require "json"

Coverage.start(methods: true, lines: true)

at_exit do
  path = ENV["COVERAGE_DUMP"]
  next unless path

  result = Coverage.result
  serializable = result.each_with_object({}) do |(file, data), map|
    methods = data[:methods]
    map[file.to_s] = if methods
                       {
                         "methods" => methods.map { |(klass, method), hits| ["#{klass}##{method}", hits.to_i] },
                         "lines" => data[:lines]
                       }
                     else
                       {"methods" => [], "lines" => data[:lines]}
                     end
  end
  File.write(path, JSON.generate(serializable))
end
