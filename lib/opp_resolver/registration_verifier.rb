# frozen_string_literal: true

require "opp"
require "date"
require "time"
require "uri"

module OppResolver
  class RegistrationVerifier
    class Invalid < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    REQUIRED_FIELDS = %w[type version subject public_key document_url sequence issued_at signature].freeze
    TYPE = "open-presence-directory-registration"
    VERSION = "0.2"
    STRING_FIELDS = %w[subject public_key document_url issued_at].freeze
    UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

    def verify!(registration, expected_subject:)
      fail_with(:malformed_registration, "The Directory Registration must be a JSON object.") unless registration.is_a?(Hash)

      missing = REQUIRED_FIELDS.reject { |field| registration.key?(field) }
      fail_with(:missing_field, "The Directory Registration is missing #{missing.first}.") unless missing.empty?

      fail_with(:unsupported_type, "The Directory Registration type is unsupported.") unless registration["type"] == TYPE
      fail_with(:unsupported_version, "The Directory Registration version is unsupported.") unless registration["version"] == VERSION
      validate_field_types!(registration)
      validate_sequence!(registration["sequence"])
      validate_timestamp!(registration["issued_at"])
      validate_document_url!(registration["document_url"])
      validate_signature_shape!(registration["signature"])

      unless registration["subject"] == expected_subject
        fail_with(:requested_subject_mismatch, "The Directory Registration belongs to a different subject.")
      end

      OPP::Subject.verify!(registration["subject"], public_key: registration["public_key"])
      OPP::Signature.verify!(registration, public_key: registration["public_key"])
      registration
    rescue OPP::InvalidPublicKeyError
      fail_with(:invalid_public_key, "The Directory Registration public key is invalid.")
    rescue OPP::SubjectMismatchError
      fail_with(:subject_mismatch, "The Directory Registration subject does not match its public key.")
    rescue OPP::InvalidSignatureError, OPP::ValidationError
      fail_with(:invalid_signature, "The Directory Registration signature is invalid.")
    end

    private

    def validate_field_types!(registration)
      field = STRING_FIELDS.find { |name| !registration[name].is_a?(String) }
      fail_with(:invalid_field, "The Directory Registration #{field} must be a string.") if field
    end

    def validate_sequence!(value)
      return if value.is_a?(Integer) && value >= 0

      fail_with(:invalid_sequence, "The Directory Registration sequence must be a non-negative integer.")
    end

    def validate_timestamp!(value)
      unless UTC_TIMESTAMP.match?(value)
        fail_with(:invalid_issued_at, "The Directory Registration issued_at must be an RFC 3339 UTC timestamp.")
      end
      DateTime.rfc3339(value)
    rescue ArgumentError
      fail_with(:invalid_issued_at, "The Directory Registration issued_at must be an RFC 3339 UTC timestamp.")
    end

    def validate_document_url!(value)
      uri = URI.parse(value)
      valid = uri.is_a?(URI::HTTPS) && uri.absolute? && !uri.host.to_s.empty? && uri.user.nil? && uri.password.nil?
      return if valid

      fail_with(:invalid_document_url, "The Presence Document URL must be absolute, credential-free HTTPS.")
    rescue URI::InvalidURIError
      fail_with(:invalid_document_url, "The Presence Document URL must be absolute, credential-free HTTPS.")
    end

    def validate_signature_shape!(signature)
      valid = signature.is_a?(Hash) &&
        signature.keys.sort == %w[algorithm value] &&
        signature["algorithm"] == "ed25519" &&
        signature["value"].is_a?(String)
      return if valid

      fail_with(:invalid_signature, "The Directory Registration signature is invalid.")
    end

    def fail_with(code, message)
      raise Invalid.new(code, message)
    end
  end
end
