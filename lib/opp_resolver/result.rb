# frozen_string_literal: true

module OppResolver
  Result = Data.define(:success?, :error_code, :message, :details) do
    def self.success(details)
      new(true, nil, nil, freeze_value(details))
    end

    def self.failure(code, message, details = {})
      new(false, code, message, freeze_value(details))
    end

    def failure? = !success?

    alias ok? success?

    def self.freeze_value(value)
      case value
      when Hash
        value.to_h { |key, item| [key, freeze_value(item)] }.freeze
      when Array
        value.map { |item| freeze_value(item) }.freeze
      when String
        value.dup.freeze
      else
        value.freeze
      end
    end
    private_class_method :freeze_value
  end
end
