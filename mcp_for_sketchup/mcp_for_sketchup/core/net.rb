# mcp_for_sketchup/mcp_for_sketchup/core/net.rb
require "socket"

module MCPforSketchUp
  module Core
    # Block C (spec §7.3): one loopback check, shared by the server's bind
    # warning and the Settings dialog's host warning.
    #
    # A host is loopback only when every address it resolves to is a loopback
    # address. Names such as localhost are resolved; a host that does not
    # resolve counts as not loopback, so it is warned about, never trusted.
    module Net
      def self.loopback?(host)
        name = host.to_s.strip
        return false if name.empty?
        addresses = Addrinfo.getaddrinfo(name, nil, nil, :STREAM)
        !addresses.empty? && addresses.all? { |a| a.ipv4_loopback? || a.ipv6_loopback? }
      rescue SocketError, ArgumentError
        false
      end
    end
  end
end
