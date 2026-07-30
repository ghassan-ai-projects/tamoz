# frozen_string_literal: true

module Tamoz
  module SQLite
    module ExceptionMapper
      module_function

      def raise_mapped(error, operation:)
        mapped = case error
                 when ::SQLite3::BusyException, ::SQLite3::LockedException
                   BusyError.new("#{operation}: SQLite remained busy")
                 when ::SQLite3::CorruptException, ::SQLite3::NotADatabaseException
                   IntegrityError.new("#{operation}: SQLite database is corrupted")
                 when ::SQLite3::PermissionException, ::SQLite3::ReadOnlyException,
                      ::SQLite3::CantOpenException
                   PermissionError.new("#{operation}: SQLite permission/open failure")
                 when ::SQLite3::FullException
                   Error.new("#{operation}: SQLite storage is full")
                 when ::SQLite3::ConstraintException
                   IntegrityError.new("#{operation}: SQLite constraint contract failed")
                 else
                   Error.new("#{operation}: SQLite failure #{error.class}")
                 end
        raise mapped, cause: error
      end
    end

    private_constant :ExceptionMapper
  end
end
