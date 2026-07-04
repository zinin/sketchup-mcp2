# test/support/fake_socket.rb — minimal in-memory socket stub for server tests.
# Behaves like a TCPSocket from the Server's perspective:
#   - read_nonblock(n) pops from queued chunks; raises IO::WaitReadable when empty
#   - write(bytes) appends to a captured buffer
#   - write_nonblock(bytes) appends to a captured buffer; honours per-test
#     stubs that simulate partial writes or IO::WaitWritable backpressure
#   - close / closed? track state
#   - peeraddr returns a deterministic [family, port, hostname, ip] tuple
#   - setsockopt is recorded (for SO_KEEPALIVE assertions in later tasks)

class FakeSocket
  attr_reader :written, :sockopts

  def initialize(read_chunks: [], peer: ["AF_INET", 54321, "127.0.0.1", "127.0.0.1"])
    @read_queue              = read_chunks.dup
    @peer                    = peer
    @written                 = String.new(encoding: Encoding::ASCII_8BIT)
    @sockopts                = []
    @closed                  = false
    @eof                     = false
    @partial_write_max_bytes = nil   # set via stub_partial_write
    @pending_waitwritable    = 0     # set via stub_write_pending
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

  # Cap each write_nonblock call to `max_bytes_per_call` bytes — the rest
  # has to be retried by the caller. If `calls` is set, only the first
  # `calls` write_nonblock invocations are capped; subsequent calls raise
  # an Errno::EAGAIN extended with IO::WaitWritable so the test can
  # observe the buffer-not-drained state at end-of-tick (mirrors a real
  # kernel send-buffer that filled up after a partial accept).
  def stub_partial_write(max_bytes_per_call:, calls: nil)
    @partial_write_max_bytes  = max_bytes_per_call
    @partial_write_remaining  = calls
  end

  # Make the next `n` write_nonblock calls raise an Errno::EAGAIN extended
  # with IO::WaitWritable (matching the real socket's signal that the
  # kernel send-buffer is full). Defaults to one occurrence.
  def stub_write_pending(times: 1)
    @pending_waitwritable = times
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

  def write_nonblock(bytes)
    raise Errno::EPIPE, "Broken pipe" if @closed
    if @pending_waitwritable > 0
      @pending_waitwritable -= 1
      raise_waitwritable!
    end
    # Partial-write stub with optional per-tick budget. Once budgeted calls
    # are exhausted, raise WaitWritable to mimic kernel-buffer pressure.
    if @partial_write_max_bytes
      if @partial_write_remaining && @partial_write_remaining <= 0
        raise_waitwritable!
      end
      payload = bytes.b
      n       = [@partial_write_max_bytes, payload.bytesize].min
      @written << payload.byteslice(0, n)
      @partial_write_remaining -= 1 if @partial_write_remaining
      return n
    end
    payload = bytes.b
    @written << payload
    payload.bytesize
  end

  def raise_waitwritable!
    # IO::WaitWritable is a module — real write_nonblock raises an
    # Errno::EAGAIN extended with it.
    e = Errno::EAGAIN.new("Resource temporarily unavailable")
    e.extend(IO::WaitWritable)
    raise e
  end
  private :raise_waitwritable!

  def flush; end

  def close
    @closed = true
  end

  def closed?
    @closed
  end

  # IO#wait_readable(timeout) probe (io/wait): truthy iff unread bytes (or a
  # pending EOF) are available. Real IO#wait_readable raises IOError on a
  # closed stream — mirror that so the server's rescue path is exercised.
  def wait_readable(_timeout = nil)
    raise IOError, "closed stream" if @closed
    (@read_queue.any? || @eof) ? self : nil
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
