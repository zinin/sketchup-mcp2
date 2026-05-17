# test/support/fake_socket.rb — minimal in-memory socket stub for server tests.
# Behaves like a TCPSocket from the Server's perspective:
#   - read_nonblock(n) pops from queued chunks; raises IO::WaitReadable when empty
#   - write(bytes) appends to a captured buffer
#   - close / closed? track state
#   - peeraddr returns a deterministic [family, port, hostname, ip] tuple
#   - setsockopt is recorded (for SO_KEEPALIVE assertions in later tasks)

class FakeSocket
  attr_reader :written, :sockopts

  def initialize(read_chunks: [], peer: ["AF_INET", 54321, "127.0.0.1", "127.0.0.1"])
    @read_queue = read_chunks.dup
    @peer       = peer
    @written    = String.new(encoding: Encoding::ASCII_8BIT)
    @sockopts   = []
    @closed     = false
    @eof        = false
  end

  # Feed more bytes into the read queue mid-test (simulates kernel buffer
  # filling after additional client traffic).
  def push_read(bytes)
    @read_queue << bytes.dup.force_encoding(Encoding::ASCII_8BIT)
  end

  # Mark next read as EOF (peer closed cleanly).
  def push_eof
    @eof = true
  end

  def read_nonblock(_n)
    if @closed
      raise IOError, "closed stream"
    end
    if @read_queue.empty?
      if @eof
        raise EOFError, "end of file reached"
      end
      # IO::WaitReadable is a module, not a class — cannot be raised directly.
      # Real read_nonblock raises an Errno::EAGAIN extended with the module.
      e = Errno::EAGAIN.new("Resource temporarily unavailable")
      e.extend(IO::WaitReadable)
      raise e
    end
    @read_queue.shift
  end

  def write(bytes)
    raise Errno::EPIPE, "Broken pipe" if @closed
    @written << bytes.b
    bytes.bytesize
  end

  def flush; end

  def close
    @closed = true
  end

  def closed?
    @closed
  end

  def peeraddr
    raise SocketError, "unconnected" if @closed
    @peer
  end

  def setsockopt(level, opt, value)
    @sockopts << [level, opt, value]
  end
end

# FakeServer — stand-in for TCPServer.  accept_nonblock pops from queued sockets.
class FakeServer
  def initialize(pending = [])
    @pending = pending.dup
    @closed  = false
  end

  def queue_accept(sock)
    @pending << sock
  end

  def accept_nonblock
    if @pending.empty?
      # IO::WaitReadable is a module — real accept_nonblock raises an
      # Errno::EAGAIN extended with it. Match the real behavior so the
      # `rescue IO::WaitReadable` clause in Server fires correctly.
      e = Errno::EAGAIN.new("no pending")
      e.extend(IO::WaitReadable)
      raise e
    end
    @pending.shift
  end

  def close
    @closed = true
  end
end
