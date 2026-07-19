# frozen_string_literal: true

require "json"
require "opp"
require "uri"
require_relative "result"
require_relative "registration_verifier"
require_relative "safe_http_client"

module OppResolver
  class Resolver
    SUBJECT_PATTERN = /\Akey:sha256:[A-Za-z0-9_-]{43}\z/

    def initialize(
      directory_url:,
      http_client: SafeHttpClient.new,
      registration_verifier: RegistrationVerifier.new,
      clock: -> { Time.now.utc }
    )
      @directory_uri = parse_directory_url(directory_url)
      @directory_url = @directory_uri.to_s.delete_suffix("/")
      @http_client = http_client
      @registration_verifier = registration_verifier
      @clock = clock
    end

    def resolve(raw_subject)
      subject = raw_subject.to_s.strip
      return failure(:invalid_subject, "Enter a valid exact OPP subject.", subject:) unless SUBJECT_PATTERN.match?(subject)

      registration_response = fetch(directory_request_uri(subject), public_only: false, stage: :directory, subject:)
      return registration_response if registration_response.is_a?(Result)
      return directory_status_failure(registration_response, subject:) unless registration_response.status == 200

      registration = parse_document(registration_response.body, stage: :registration, subject:)
      return registration if registration.is_a?(Result)

      begin
        registration_verifier.verify!(registration, expected_subject: subject)
      rescue RegistrationVerifier::Invalid => error
        return failure(error.code, error.message, subject:, stage: :registration, registration_found: true)
      end

      presence_response = fetch(registration["document_url"], public_only: true, stage: :presence, subject:)
      return presence_response if presence_response.is_a?(Result)
      return failure(:presence_unavailable, "The Presence Document could not be retrieved.", subject:, stage: :presence) unless presence_response.status == 200

      presence = parse_document(presence_response.body, stage: :presence, subject:)
      return presence if presence.is_a?(Result)

      verification = OPP::Presence.verify(presence, at: clock.call)
      unless verification.valid?
        errors = verification.errors.map { |error| verification_error(error) }
        return presence_verification_failure(errors, subject:)
      end

      unless presence["subject"] == subject
        return failure(
          :presence_subject_mismatch,
          "The Presence Document belongs to a different subject.",
          subject:,
          stage: :presence
        )
      end

      Result.success(
        subject:,
        directory_url:,
        registration_found: true,
        registration:,
        presence:,
        services: presence.fetch("services"),
        registration_json: JSON.pretty_generate(registration),
        presence_json: JSON.pretty_generate(presence)
      )
    end

    private

    attr_reader :directory_uri, :directory_url, :http_client, :registration_verifier, :clock

    def parse_directory_url(value)
      uri = URI.parse(value.to_s)
      valid = uri.is_a?(URI::HTTPS) && uri.absolute? && !uri.host.to_s.empty? &&
        uri.user.nil? && uri.password.nil? && uri.query.nil? && uri.fragment.nil?
      raise ArgumentError, "directory URL must be absolute, credential-free HTTPS" unless valid

      uri
    rescue URI::InvalidURIError
      raise ArgumentError, "directory URL must be absolute, credential-free HTTPS"
    end

    def directory_request_uri(subject)
      directory_uri.dup.tap do |uri|
        base_path = uri.path.to_s.delete_suffix("/")
        uri.path = "#{base_path}/#{URI.encode_www_form_component(subject)}"
      end
    end

    def fetch(url, public_only:, stage:, subject:)
      http_client.get(url, public_only:)
    rescue SafeHttpClient::Failure => error
      code = network_error_code(stage, error.code)
      message = stage == :directory ? "The OPP directory is unavailable." : "The Presence Document could not be retrieved safely."
      failure(code, message, subject:, stage:)
    end

    def network_error_code(stage, code)
      return :directory_timeout if stage == :directory && code == :timeout
      return "directory_#{code}".to_sym if stage == :directory && %i[response_too_large invalid_content_type].include?(code)
      return :directory_unavailable if stage == :directory

      "presence_#{code}".to_sym
    end

    def directory_status_failure(response, subject:)
      if response.status == 404
        failure(:registration_not_found, "No Directory Registration was found for this subject.", subject:, stage: :directory)
      else
        failure(:directory_unavailable, "The OPP directory is unavailable.", subject:, stage: :directory)
      end
    end

    def parse_document(body, stage:, subject:)
      OPP::JSON.parse(body)
    rescue OPP::ParseError, OPP::DuplicateMemberError
      code = stage == :registration ? :malformed_registration : :malformed_presence
      label = stage == :registration ? "Directory Registration" : "Presence Document"
      failure(code, "The #{label} is not valid JSON.", subject:, stage:)
    end

    def presence_verification_failure(errors, subject:)
      codes = errors.map { |error| error[:code] }
      code, message = if codes.include?("expired_document")
        [:expired_presence, "The Presence Document has expired."]
      elsif (codes - ["invalid_signature"]).empty?
        [:invalid_presence_signature, "The Presence Document signature is invalid."]
      else
        [:invalid_presence, "The Presence Document did not pass verification."]
      end
      failure(code, message, subject:, stage: :presence, verification_errors: errors)
    end

    def verification_error(error)
      { code: error.code.to_s, path: error.path, message: error.message }.compact
    end

    def failure(code, message, details = {})
      Result.failure(code, message, { directory_url: }.merge(details))
    end
  end
end
