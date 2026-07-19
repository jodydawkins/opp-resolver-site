# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "openssl"
require "socket"
require "timeout"
require "uri"

module OppResolver
  class SafeHttpClient
    Response = Data.define(:status, :body, :content_type)

    class Failure < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    class DnsResolver
      def resolve(host)
        Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map { |entry| IPAddr.new(entry.ip_address) }.uniq
      end
    end

    class NetHttpTransport
      def get(uri:, ipaddr:, open_timeout:, read_timeout:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.ipaddr = ipaddr if ipaddr
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        request = Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json")

        http.start do |session|
          session.request(request) do |response|
            chunks = Enumerator.new { |stream| response.read_body { |chunk| stream << chunk } }
            return yield response.code.to_i, response.to_hash, chunks
          end
        end
      end
    end

    DENIED_NETWORKS = %w[
      0.0.0.0/8
      10.0.0.0/8
      100.64.0.0/10
      127.0.0.0/8
      169.254.0.0/16
      172.16.0.0/12
      192.0.0.0/24
      192.0.2.0/24
      192.168.0.0/16
      198.18.0.0/15
      198.51.100.0/24
      203.0.113.0/24
      224.0.0.0/4
      240.0.0.0/4
      ::/128
      ::1/128
      ::ffff:0:0/96
      64:ff9b::/96
      100::/64
      2001:db8::/32
      fc00::/7
      fe80::/10
      ff00::/8
    ].map { |network| IPAddr.new(network) }.freeze

    DEFAULT_OPEN_TIMEOUT = 3
    DEFAULT_READ_TIMEOUT = 5
    DEFAULT_MAX_BYTES = 1_048_576

    def initialize(
      resolver: DnsResolver.new,
      transport: NetHttpTransport.new,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      max_bytes: DEFAULT_MAX_BYTES
    )
      @resolver = resolver
      @transport = transport
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @max_bytes = max_bytes
    end

    def get(url, public_only:)
      uri = valid_uri(url)
      ipaddr = public_only ? validated_address(uri.host) : nil
      status, headers, chunks = transport.get(
        uri:,
        ipaddr: ipaddr&.to_s,
        open_timeout:,
        read_timeout:
      ) { |*response| response }

      fail_with(:redirect, "Redirects are not allowed.") if status.between?(300, 399)

      body = read_body(headers, chunks)
      content_type = normalized_content_type(headers)
      if status.between?(200, 299) && !json_content_type?(content_type)
        fail_with(:invalid_content_type, "The remote service did not return JSON.")
      end

      Response.new(status, body, content_type)
    rescue Failure
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      fail_with(:timeout, "The remote service timed out.")
    rescue SocketError, OpenSSL::SSL::SSLError, SystemCallError, IOError
      fail_with(:unavailable, "The remote service is unavailable.")
    end

    private

    attr_reader :resolver, :transport, :open_timeout, :read_timeout, :max_bytes

    def valid_uri(url)
      uri = url.is_a?(URI) ? url.dup : URI.parse(url.to_s)
      valid = uri.is_a?(URI::HTTPS) && uri.absolute? && !uri.host.to_s.empty? && uri.user.nil? && uri.password.nil?
      return uri if valid

      fail_with(:invalid_url, "The remote URL must be absolute, credential-free HTTPS.")
    rescue URI::InvalidURIError
      fail_with(:invalid_url, "The remote URL must be absolute, credential-free HTTPS.")
    end

    def validated_address(host)
      addresses = resolver.resolve(host).map { |address| address.is_a?(IPAddr) ? address : IPAddr.new(address) }
      if addresses.empty? || addresses.any? { |address| denied_address?(address) }
        fail_with(:unsafe_address, "The remote URL resolves to an unsafe address.")
      end

      addresses.first
    end

    def denied_address?(address)
      DENIED_NETWORKS.any? { |network| network.include?(address) }
    end

    def read_body(headers, chunks)
      content_length = header(headers, "content-length")
      fail_with(:response_too_large, "The remote response is too large.") if content_length && integer(content_length) > max_bytes

      body = String.new(encoding: Encoding::BINARY)
      chunks.each do |chunk|
        fail_with(:response_too_large, "The remote response is too large.") if body.bytesize + chunk.bytesize > max_bytes

        body << chunk
      end
      body
    end

    def integer(value)
      Integer(value, 10)
    rescue ArgumentError
      0
    end

    def normalized_content_type(headers)
      header(headers, "content-type")&.split(";", 2)&.first&.strip&.downcase
    end

    def json_content_type?(content_type)
      content_type == "application/json" || content_type&.match?(%r{\Aapplication/[a-z0-9.!#$&^_-]+\+json\z})
    end

    def header(headers, name)
      value = headers[name] || headers[name.capitalize]
      Array(value).first
    end

    def fail_with(code, message)
      raise Failure.new(code, message)
    end
  end
end
