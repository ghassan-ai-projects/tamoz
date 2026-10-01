# frozen_string_literal: true

require 'fileutils'

module Tamoz
  module Core
    # A directory only its owner can enter, whether it was just created or already existed with looser bits.
    module PrivateDirectory
      MODE = 0o700

      module_function

      def secure(path)
        FileUtils.mkdir_p(path, mode: MODE)
        File.chmod(MODE, path)
      end
    end
  end
end
