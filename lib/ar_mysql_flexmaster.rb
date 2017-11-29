# frozen_string_literal: true
require 'active_record/version'

module ArMysqlFlexmaster
  class << self
    private

    def nullable_connection?
      return false if ActiveRecord::VERSION::MAJOR == 4 && ActiveRecord::VERSION::MINOR == 2 && ActiveRecord::VERSION::TINY >= 8
      return false if ActiveRecord::VERSION::MAJOR == 5 && ActiveRecord::VERSION::MINOR == 0 && ActiveRecord::VERSION::TINY >= 1
      return false if ActiveRecord::VERSION::MAJOR == 5 && ActiveRecord::VERSION::MINOR >= 1

      true
    end
  end

  NULLABLE_CONNECTION = nullable_connection?
end
