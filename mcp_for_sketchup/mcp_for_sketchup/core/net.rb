# mcp_for_sketchup/mcp_for_sketchup/core/net.rb
require "ipaddr"
require "socket"

module MCPforSketchUp
  module Core
    # Block C (spec §7.3): one loopback check, shared by the server's bind
    # warning and the Settings dialog's host warning.
    #
    # A host is loopback only when every address it resolves to is a loopback
    # address. An IP literal and localhost are judged without a lookup; other
    # names are resolved, and one that does not resolve counts as not loopback,
    # so it is warned about, never trusted.
    module Net
      # resolve: false answers without a name lookup — for the Settings
      # dialog, which asks while the user types, on SketchUp's UI thread, where
      # a lookup (of a half-typed address too) can block for seconds. A name
      # that would need one then counts as not loopback.
      def self.loopback?(host, resolve: true)
        name = host.to_s.strip
        return false if name.empty?
        literal = ip_literal(name)
        return literal.loopback? if literal
        return true if name.downcase.chomp(".") == "localhost"
        return false unless resolve
        addresses = Addrinfo.getaddrinfo(name, nil, nil, :STREAM)
        !addresses.empty? && addresses.all? { |a| a.ipv4_loopback? || a.ipv6_loopback? }
      rescue SocketError, ArgumentError
        false
      end

      # The address, when `name` is an IPv4 or IPv6 literal; IPAddr parses
      # without a lookup.
      def self.ip_literal(name)
        IPAddr.new(name)
      rescue ArgumentError
        nil
      end
      private_class_method :ip_literal
    end
  end
end
