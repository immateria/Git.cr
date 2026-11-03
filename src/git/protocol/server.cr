module Git
  module Protocol
    # The serving side of a Git service: what it advertises when a client
    # connects, and how it answers one request.
    abstract class Server
      abstract def advertise(io : IO) : Nil

      # Serve one request read from input, writing the response. Returns
      # false at a clean end of input (no further request).
      abstract def handle(input : IO, output : IO) : Bool
    end
  end
end
